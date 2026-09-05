# frozen_string_literal: true

require_relative "test_helper"

class AuthenticationTest < Minitest::Test
  ORIGIN = "https://api.example.com"

  def test_cross_origin_redirects_remove_explicit_credentials_case_insensitively
    [301, 302, 303, 307, 308].each do |status|
      headers = {
        "aUtHoRiZaTiOn" => "Bearer test-token",
        "cOoKiE" => "session=test-session",
        "pRoXy-AuThOrIzAtIoN" => "Basic test-proxy",
        "X-Public" => "keep"
      }
      protocol = redirect_protocol("https://other.example.com/final", status)
      call_http(protocol, headers: headers)

      first, last = protocol.requests
      %w[authorization cookie proxy-authorization].each do |name|
        assert first[:headers].key?(name)
        refute last[:headers].key?(name), "#{name} survived redirect #{status}"
      end
      assert_equal "keep", last[:headers]["x-public"]
      assert_equal "Bearer test-token", headers["aUtHoRiZaTiOn"]
    end
  end

  def test_same_origin_redirect_keeps_explicit_credentials
    protocol = redirect_protocol("/final", 302)
    call_http(protocol, headers: { "Authorization" => "Bearer test-token", "Cookie" => "session=test-session" })

    assert_equal "Bearer test-token", protocol.requests.last[:headers]["authorization"]
    assert_equal "session=test-session", protocol.requests.last[:headers]["cookie"]
  end

  def test_origin_change_by_port_or_scheme_removes_credentials
    ["https://localhost:8443/final", "http://localhost/final"].each do |target|
      protocol = redirect_protocol(target, 302)
      call_http(protocol, url: "https://localhost/resource", headers: { "Authorization" => "Bearer test-token" })
      refute protocol.requests.last[:headers].key?("authorization")
    end
  end

  def test_custom_api_key_and_explicit_credentials_are_both_removed
    protocol = redirect_protocol("https://other.example.com/final", 302)
    call_http(
      protocol,
      auth: { auth_type: "api_key", api_key: "test-key", var_name: "X-Custom-Key" },
      headers: { "Authorization" => "Bearer test-token", "Cookie" => "session=test-session" }
    )

    %w[x-custom-key authorization cookie].each do |name|
      assert protocol.requests.first[:headers].key?(name)
      refute protocol.requests.last[:headers].key?(name)
    end
  end

  def test_credentials_are_not_restored_when_redirect_returns_to_original_origin
    protocol = FakeHTTPProtocol.new do |request|
      case request[:target]
      when "/resource" then redirect_response("https://other.example.com/relay", 302)
      when "/relay" then redirect_response("#{ORIGIN}/final", 302)
      else json_response("ok" => true)
      end
    end
    call_http(protocol, headers: { "Authorization" => "Bearer test-token", "Cookie" => "session=test-session" })

    assert_equal 3, protocol.requests.length
    protocol.requests.drop(1).each do |request|
      refute request[:headers].key?("authorization")
      refute request[:headers].key?("cookie")
    end
  end

  def test_regular_tool_post_body_survives_cross_origin_307
    protocol = redirect_protocol("https://other.example.com/final", 307)
    call_http(protocol, arguments: { body: { message: "hello" } }, http_method: "POST", body_field: "body")

    assert_equal "POST", protocol.requests.last[:method]
    assert_equal({ "message" => "hello" }, JSON.parse(protocol.requests.last[:body]))
  end

  def test_oauth_rejects_cross_origin_redirects_before_sending_another_request
    [301, 302, 303, 307, 308].each do |status|
      protocol = FakeHTTPProtocol.new { redirect_response("https://other.example.com/token", status) }

      error = assert_raises(UTCP::SecurityError) { call_http(protocol, auth: oauth_auth) }
      assert_match(/redirect/i, error.message)
      assert_equal ["/token"], protocol.requests.map { |request| request[:target] }
    end
  end

  def test_oauth_redirect_restriction_survives_a_same_origin_hop
    protocol = FakeHTTPProtocol.new do |request|
      target = request[:target] == "/token" ? "/token-relay" : "https://other.example.com/token"
      redirect_response(target, 307)
    end

    assert_raises(UTCP::SecurityError) { call_http(protocol, auth: oauth_auth) }
    assert_equal ["/token", "/token-relay"], protocol.requests.map { |request| request[:target] }
  end

  def test_oauth_allows_same_origin_redirects_and_preserves_form_body
    [307, 308].each do |status|
      protocol = FakeHTTPProtocol.new do |request|
        case request[:target]
        when "/token" then redirect_response("/token-final", status)
        when "/token-final" then json_response("access_token" => "test-token", "expires_in" => 300)
        else json_response("ok" => true)
        end
      end
      call_http(protocol, auth: oauth_auth)

      first, redirected, resource = protocol.requests
      assert_equal "POST", redirected[:method]
      assert_equal first[:body], redirected[:body]
      assert_equal "test-secret", URI.decode_www_form(redirected[:body]).to_h["client_secret"]
      assert_equal "Bearer test-token", resource[:headers]["authorization"]
    end
  end

  def test_oauth_cache_separates_secrets_and_reuses_matching_credentials
    protocol = token_protocol
    %w[first-secret second-secret first-secret second-secret].each do |secret|
      call_http(protocol, auth: oauth_auth(client_secret: secret))
      assert_equal "Bearer token-for-#{secret}", protocol.requests.last[:headers]["authorization"]
    end
    assert_equal 2, protocol.requests.count { |request| request[:target] == "/token" }
  end

  def test_oauth_refreshes_credentials_after_in_place_secret_change
    protocol = token_protocol
    credentials = oauth_auth(client_secret: +"first-secret")
    call_http(protocol, auth: credentials)
    credentials.client_secret.replace("second-secret")
    call_http(protocol, auth: credentials)

    assert_equal 2, protocol.requests.count { |request| request[:target] == "/token" }
    assert_equal "Bearer token-for-second-secret", protocol.requests.last[:headers]["authorization"]
  end

  def test_oauth_does_not_fall_back_to_cached_token_when_changed_secret_is_rejected
    protocol = FakeHTTPProtocol.new do |request|
      if request[:target] == "/token"
        fields = URI.decode_www_form(request[:body]).to_h
        if fields["client_secret"] == "test-secret"
          json_response("access_token" => "test-token", "expires_in" => 300)
        else
          FakeHTTPResponse.new(code: 401)
        end
      else
        json_response("ok" => true)
      end
    end
    call_http(protocol, auth: oauth_auth)

    assert_raises(UTCP::AuthenticationError) do
      call_http(protocol, auth: oauth_auth(client_secret: "incorrect-secret"))
    end
    assert_equal 2, protocol.requests.count { |request| request[:target] == "/token" }
    assert_equal 1, protocol.requests.count { |request| request[:target] == "/resource" }
  end

  private

  def call_http(protocol, arguments: {}, **options)
    template = UTCP::HttpCallTemplate.new(**{ url: "#{ORIGIN}/resource" }.merge(options))
    protocol.call_tool(nil, "api.resource", arguments, template)
  end

  def oauth_auth(**options)
    UTCP::OAuth2Auth.new(**{
      token_url: "#{ORIGIN}/token", client_id: "test-client", client_secret: "test-secret", scope: "read"
    }.merge(options))
  end

  def json_response(value)
    FakeHTTPResponse.new(body: JSON.generate(value), headers: { "Content-Type" => "application/json" })
  end

  def redirect_response(target, status)
    FakeHTTPResponse.new(code: status, headers: { "Location" => target })
  end

  def redirect_protocol(target, status)
    FakeHTTPProtocol.new do |request|
      request[:target] == "/resource" ? redirect_response(target, status) : json_response("ok" => true)
    end
  end

  def token_protocol
    FakeHTTPProtocol.new do |request|
      if request[:target] == "/token"
        secret = URI.decode_www_form(request[:body]).to_h.fetch("client_secret")
        json_response("access_token" => "token-for-#{secret}", "expires_in" => 300)
      else
        json_response("ok" => true)
      end
    end
  end
end
