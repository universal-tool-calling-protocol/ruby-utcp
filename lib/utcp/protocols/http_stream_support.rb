# frozen_string_literal: true

module UTCP
  module HTTPStreamSupport
    private

    def buffered_discovery(template)
      parts = http_parts(template, {}, discovery: true, accept: "application/json")
      perform_request(
        parts[:method], parts[:uri], headers: parts[:headers], cookies: parts[:cookies],
        body: parts[:body], content_type: parts[:content_type], timeout: parts[:timeout],
        sensitive_headers: parts[:sensitive_headers]
      )
    end

    def with_stream_response(template, arguments, accept: nil)
      parts = http_parts(template, arguments, discovery: false, accept: accept)
      request_class = HTTPProtocol::REQUEST_CLASSES.fetch(parts[:method])
      request = request_class.new(parts[:uri].request_uri)
      parts[:headers].each do |name, value|
        assert_header_safe!(name, "header name")
        assert_header_safe!(value.to_s, "header value")
        request[name] = value.to_s
      end
      unless parts[:cookies].empty?
        request["Cookie"] = parts[:cookies].map { |key, value| "#{key}=#{value}" }.join("; ")
      end
      unless parts[:body].nil?
        request["Content-Type"] ||= parts[:content_type]
        request.body = parts[:content_type].include?("json") && !parts[:body].is_a?(String) ?
          JSON.generate(parts[:body]) : parts[:body].to_s
      end

      send_stream_request(parts[:uri], request, parts[:timeout]) do |response|
        validate_stream_response!(response)
        yield response
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => error
      raise TimeoutError, "Streaming HTTP request timed out: #{error.message}"
    rescue Error
      raise
    rescue SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => error
      raise ToolCallError, "Streaming HTTP request failed: #{error.message}"
    end

    def http_parts(template, arguments, discovery:, accept: nil)
      headers = Utils.stringify_keys(template.headers || {})
      headers["Accept"] = accept if accept
      query = {}
      cookies = {}
      args = Utils.stringify_keys(arguments || {})
      body = nil

      unless discovery
        Array(template.header_fields).each do |field|
          headers[field] = args.delete(field).to_s if args.key?(field)
        end
        body = args.delete(template.body_field) if template.body_field && args.key?(template.body_field)
      end

      url = discovery ? template.url : interpolate_url(template.url, args)
      query.merge!(args) unless discovery
      sensitive = apply_auth(template.auth, headers, query, cookies)
      if template.auth.is_a?(OAuth2Auth)
        headers["Authorization"] = "Bearer #{oauth_token(template.auth)}"
        sensitive << "Authorization"
      end
      method = if discovery
                 template.respond_to?(:http_method) ? template.http_method : "GET"
               elsif template.is_a?(SseCallTemplate)
                 body.nil? ? "GET" : "POST"
               else
                 template.http_method
               end
      content_type = template.respond_to?(:content_type) ? template.content_type : "application/json"
      timeout = protocol_timeout_seconds(template, discovery)
      uri = URLSecurity.validate!(append_query(url, query), context: discovery ? "manual discovery" : "tool invocation")
      {
        method: method.to_s.upcase,
        uri: uri,
        headers: headers,
        cookies: cookies,
        body: body,
        content_type: content_type,
        timeout: timeout,
        sensitive_headers: sensitive.uniq
      }
    end

    def protocol_timeout_seconds(template, discovery)
      return 10 if discovery
      return template.timeout / 1000.0 if template.is_a?(StreamableHttpCallTemplate)

      template.timeout || 30
    end

    def send_stream_request(uri, request, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [Float(timeout), 10].min
      http.read_timeout = Float(timeout)
      http.start do |connection|
        connection.request(request) { |response| yield response }
      end
    end

    def validate_stream_response!(response)
      status = response.code.to_i
      if HTTPProtocol::REDIRECTS.include?(status)
        raise SecurityError, "Streaming HTTP redirects are not followed; use the final endpoint URL"
      end
      if status == 401 || status == 403
        raise AuthenticationError, "HTTP authentication failed with status #{status}"
      end
      return if status.between?(200, 299)

      body = response.respond_to?(:body) ? response.body : nil
      raise ToolCallError.new("HTTP request failed with status #{status}", status: status, response_body: body)
    end
  end
end
