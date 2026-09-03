# frozen_string_literal: true

require "base64"
require "ipaddr"
require "json"
require "net/http"
require "openssl"
require "uri"

module UTCP
  module URLSecurity
    module_function

    def validate!(url, context: "HTTP request")
      uri = URI.parse(url.to_s)
      raise SecurityError, "#{context} URL must use HTTP or HTTPS" unless %w[http https].include?(uri.scheme)
      raise SecurityError, "#{context} URL must contain a host" if uri.host.nil? || uri.host.empty?
      raise SecurityError, "#{context} URL must not contain user information" if uri.userinfo

      if uri.scheme == "http" && !loopback_host?(uri.host)
        raise SecurityError, "#{context} refuses plain HTTP except for loopback hosts"
      end
      uri
    rescue URI::InvalidURIError => error
      raise SecurityError, "Invalid #{context} URL: #{error.message}"
    end

    def loopback_host?(host)
      normalized = host.to_s.downcase.sub(/\A\[/, "").sub(/\]\z/, "").sub(/\.\z/, "")
      return true if normalized == "localhost" || normalized.end_with?(".localhost")

      IPAddr.new(normalized).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def same_origin?(first, second)
      [first.scheme, first.host&.downcase, first.port] == [second.scheme, second.host&.downcase, second.port]
    end
  end

  class HTTPProtocol < CommunicationProtocol
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    REQUEST_CLASSES = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "PUT" => Net::HTTP::Put,
      "DELETE" => Net::HTTP::Delete,
      "PATCH" => Net::HTTP::Patch,
      "HEAD" => Net::HTTP::Head,
      "OPTIONS" => Net::HTTP::Options
    }.freeze

    def initialize(open_timeout: 10, read_timeout: 30, max_redirects: 5)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_redirects = max_redirects
      @oauth_tokens = {}
      @oauth_mutex = Mutex.new
    end

    def register_manual(client, template)
      assert_template!(template)
      response = request(template, {}, discovery: true)
      data = parse_document(response.body, response["content-type"], template.url)
      manual = if data.is_a?(Hash) && data.key?("utcp_version") && data.key?("tools")
                 Manual.from_h(data)
               else
                 OpenAPIConverter.new(
                   data,
                   spec_url: template.url,
                   call_template_name: template.name,
                   auth_tools: template.auth_tools
                 ).convert
               end
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register HTTP manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_template!(template)
      response = request(template, Utils.stringify_keys(tool_args || {}), discovery: false)
      parse_response(response)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new(
        "HTTP tool #{tool_name.inspect} failed: #{error.message}",
        tool_name: tool_name
      )
    end

    private

    def assert_template!(template)
      return if template.is_a?(HttpCallTemplate)

      raise ValidationError, "HTTP protocol requires an HttpCallTemplate"
    end

    def request(template, arguments, discovery:)
      headers = Utils.stringify_keys(template.headers || {})
      query = {}
      cookies = {}
      body = nil
      args = arguments.dup

      unless discovery
        template.header_fields.each do |field|
          next unless args.key?(field)

          headers[field] = args.delete(field).to_s
        end
        body = args.delete(template.body_field) if template.body_field && args.key?(template.body_field)
      end

      url = discovery ? template.url : interpolate_url(template.url, args)
      query.merge!(args) unless discovery
      sensitive_headers = apply_auth(template.auth, headers, query, cookies)
      if template.auth.is_a?(OAuth2Auth)
        headers["Authorization"] = "Bearer #{oauth_token(template.auth)}"
        sensitive_headers << "Authorization"
      end

      uri = URLSecurity.validate!(append_query(url, query), context: discovery ? "manual discovery" : "tool invocation")
      timeout = template.timeout || (discovery ? @open_timeout : @read_timeout)
      perform_request(
        template.http_method,
        uri,
        headers: headers,
        cookies: cookies,
        body: body,
        content_type: template.content_type,
        timeout: timeout,
        sensitive_headers: sensitive_headers.uniq
      )
    end

    def interpolate_url(url, arguments)
      result = url.gsub(/\{([^}]+)\}/) do
        name = Regexp.last_match(1)
        raise ToolCallError, "Missing required path parameter: #{name}" unless arguments.key?(name)

        percent_encode(arguments.delete(name).to_s)
      end
      remaining = result.scan(/\{([^}]+)\}/).flatten
      raise ToolCallError, "Missing required path parameters: #{remaining.join(', ')}" unless remaining.empty?

      result
    end

    def percent_encode(value)
      value.encode(Encoding::UTF_8).bytes.map do |byte|
        character = byte.chr
        character.match?(/[A-Za-z0-9\-._~]/) ? character : format("%%%02X", byte)
      end.join
    end

    def append_query(url, query)
      return url if query.empty?

      uri = URI.parse(url)
      existing = URI.decode_www_form(uri.query.to_s)
      additions = query.flat_map do |key, value|
        values = value.is_a?(Array) ? value : [value]
        values.map { |item| [key.to_s, encode_query_value(item)] }
      end
      uri.query = URI.encode_www_form(existing + additions)
      uri.to_s
    rescue URI::InvalidURIError => error
      raise ToolCallError, "Invalid HTTP URL: #{error.message}"
    end

    def encode_query_value(value)
      value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
    end

    def apply_auth(auth, headers, query, cookies)
      return [] unless auth

      case auth
      when ApiKeyAuth
        assert_header_safe!(auth.var_name, "API key name")
        case auth.location
        when "header"
          headers[auth.var_name] = auth.api_key
          [auth.var_name]
        when "query"
          query[auth.var_name] = auth.api_key
          []
        when "cookie"
          cookies[auth.var_name] = auth.api_key
          ["Cookie"]
        end
      when BasicAuth
        token = Base64.strict_encode64("#{auth.username}:#{auth.password}")
        headers["Authorization"] = "Basic #{token}"
        ["Authorization"]
      when OAuth2Auth
        ["Authorization"]
      else
        raise AuthenticationError, "Unsupported authentication type: #{auth.auth_type}"
      end
    end

    def oauth_token(auth)
      @oauth_mutex.synchronize do
        cache_key = [auth.token_url, auth.client_id, auth.scope]
        cached = @oauth_tokens[cache_key]
        return cached[:token] if cached && cached[:expires_at] > Time.now.to_f + 5

        token_uri = URLSecurity.validate!(auth.token_url, context: "OAuth2 token")
        fields = {
          "grant_type" => "client_credentials",
          "client_id" => auth.client_id,
          "client_secret" => auth.client_secret
        }
        fields["scope"] = auth.scope if auth.scope
        response = perform_request(
          "POST", token_uri,
          headers: {}, cookies: {}, body: URI.encode_www_form(fields),
          content_type: "application/x-www-form-urlencoded", timeout: @open_timeout,
          sensitive_headers: ["Authorization"]
        )
        data = JSON.parse(response.body)
        token = data["access_token"]
        raise AuthenticationError, "OAuth2 response did not contain access_token" if token.nil? || token.empty?

        expires_in = Float(data.fetch("expires_in", 3600)) rescue 3600.0
        @oauth_tokens[cache_key] = { token: token, expires_at: Time.now.to_f + expires_in }
        token
      rescue Error
        raise
      rescue StandardError => error
        raise AuthenticationError, "OAuth2 token request failed: #{error.message}"
      end
    end

    def perform_request(method, uri, headers:, cookies:, body:, content_type:, timeout:,
                        sensitive_headers:, redirects: 0)
      URLSecurity.validate!(uri.to_s, context: "HTTP request")
      raise ToolCallError, "Too many HTTP redirects" if redirects > @max_redirects

      request_class = REQUEST_CLASSES[method.to_s.upcase]
      raise ValidationError, "Unsupported HTTP method: #{method}" unless request_class

      request = request_class.new(uri.request_uri)
      headers.each do |name, value|
        assert_header_safe!(name, "header name")
        assert_header_safe!(value.to_s, "header value")
        request[name] = value.to_s
      end
      unless cookies.empty?
        cookies.each do |name, value|
          assert_header_safe!(name, "cookie name")
          assert_header_safe!(value, "cookie value")
        end
        request["Cookie"] = cookies.map { |key, value| "#{key}=#{value}" }.join("; ")
      end
      unless body.nil?
        request["Content-Type"] ||= content_type
        request.body = content_type.to_s.include?("json") && !body.is_a?(String) ? JSON.generate(body) : body.to_s
      end

      response = send_request(uri, request, timeout)
      if REDIRECTS.include?(response.code.to_i) && response["location"]
        target = URI.join(uri.to_s, response["location"])
        URLSecurity.validate!(target.to_s, context: "HTTP redirect")
        next_headers = headers.dup
        next_cookies = cookies.dup
        unless URLSecurity.same_origin?(uri, target)
          sensitive_headers.each { |name| next_headers.delete_if { |key, _| key.casecmp?(name) } }
          next_cookies = {}
        end
        next_method = response.code.to_i == 303 || ([301, 302].include?(response.code.to_i) && method.to_s.upcase == "POST") ? "GET" : method
        next_body = next_method == "GET" ? nil : body
        return perform_request(
          next_method, target, headers: next_headers, cookies: next_cookies,
          body: next_body, content_type: content_type, timeout: timeout,
          sensitive_headers: sensitive_headers, redirects: redirects + 1
        )
      end

      status = response.code.to_i
      if status == 401 || status == 403
        raise AuthenticationError, "HTTP authentication failed with status #{status}"
      end
      unless status.between?(200, 299)
        raise ToolCallError.new(
          "HTTP request failed with status #{status}",
          status: status,
          response_body: response.body
        )
      end
      response
    rescue Net::OpenTimeout, Net::ReadTimeout => error
      raise TimeoutError, "HTTP request timed out: #{error.message}"
    rescue SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => error
      raise ToolCallError, "HTTP request failed: #{error.message}"
    end

    def send_request(uri, request, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [Float(timeout), @open_timeout].min
      http.read_timeout = Float(timeout)
      http.start { |connection| connection.request(request) }
    end

    def parse_document(body, content_type, url)
      if content_type.to_s.downcase.include?("yaml") || url.end_with?(".yaml", ".yml")
        value = YAML.safe_load(body, permitted_classes: [], permitted_symbols: [], aliases: false)
        Utils.stringify_keys(value)
      else
        Utils.stringify_keys(JSON.parse(body))
      end
    rescue JSON::ParserError, Psych::Exception => error
      raise SerializerValidationError, "Invalid manual response: #{error.message}"
    end

    def parse_response(response)
      content_type = response["content-type"].to_s.downcase
      return response.body unless content_type.include?("json")

      JSON.parse(response.body)
    rescue JSON::ParserError
      response.body
    end

    def assert_header_safe!(value, field)
      return unless value.to_s.match?(/[\r\n]/)

      raise SecurityError, "#{field} contains CR/LF"
    end
  end
  HttpCommunicationProtocol = HTTPProtocol
end
