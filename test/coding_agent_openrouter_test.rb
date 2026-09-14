# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../examples/coding_agent/openrouter"

class CodingAgentOpenRouterTest < Minitest::Test
  class ScriptedHTTP
    attr_reader :requests, :finishes

    def initialize(&handler)
      @handler = handler
      @requests = []
      @started = false
      @finishes = 0
    end

    def started?
      @started
    end

    def start
      @started = true
    end

    def finish
      @finishes += 1
      @started = false
    end

    def request(request)
      @requests << request
      @handler.call(request)
    end
  end

  def setup
    @log = StringIO.new
  end

  def teardown
    @router.close if @router
  end

  def router(**options, &handler)
    @http = ScriptedHTTP.new(&handler)
    @router = CodingAgent::OpenRouter.new(api_key: "test-secret", log: @log, **options)
    @router.instance_variable_set(:@http, @http)
    @router
  end

  def success(content = "FINAL: Done")
    FakeHTTPResponse.new(body: JSON.generate("choices" => [{
      "finish_reason" => "stop", "message" => {
        "role" => "assistant", "content" => content, "reasoning_details" => [{ "text" => "provider metadata" }]
      }
    }]))
  end

  def complete
    @router.complete(messages: [{ "role" => "user", "content" => "Inspect a file" }])
  end

  def test_requests_use_a_smaller_output_budget_and_keep_the_selected_model
    router(model: "nvidia/nemotron-3.5-lightning:free") { success }
    result = complete
    payload = JSON.parse(@http.requests.first.body)
    assert_equal 4096, payload.fetch("max_tokens")
    assert_equal "nvidia/nemotron-3.5-lightning:free", payload.fetch("model")
    assert_equal false, payload.fetch("stream")
    refute payload.key?("tools")
    assert_equal "FINAL: Done", result.fetch("content")
    assert_equal [{ "text" => "provider metadata" }], result.fetch("reasoning_details")
    assert_includes @log.string, "Waiting for nvidia/nemotron-3.5-lightning:free"
    assert_includes @log.string, "Model response received after"
    refute_includes @log.string, "test-secret"
  end

  def test_timeout_closes_the_connection_and_stops_progress_without_waiting_for_its_interval
    router(request_timeout: 0.03) { sleep 1; success }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(CodingAgent::Error) { complete }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.8
    assert_includes error.message, "exceeded 0.03s, including retries"
    assert_includes error.message, "No program from this request was executed"
    assert_equal 1, @http.finishes
    refute @http.started?
    assert_nil @router.instance_variable_get(:@http)
    refute_includes @log.string, "Model response received"
  end

  def test_deadline_is_shared_by_retries_and_backoff
    delays = []
    sleeper = lambda do |seconds|
      delays << seconds
      sleep 0.1
    end
    router(request_timeout: 0.03, sleeper: sleeper) do
      FakeHTTPResponse.new(code: 503, body: JSON.generate("error" => { "message" => "busy" }))
    end
    error = assert_raises(CodingAgent::Error) { complete }
    assert_includes error.message, "including retries"
    assert_equal [2], delays
    assert_equal 1, @http.requests.length
    assert_equal 1, @http.finishes
    assert_includes @log.string, "retry 1/2 in 2s"
  end

  def test_retry_progress_and_persistent_connection_on_recovery
    delays = []
    responses = [
      FakeHTTPResponse.new(code: 429, headers: { "Retry-After" => "2" }, body: "{}"),
      success
    ]
    router(sleeper: ->(seconds) { delays << seconds }) { responses.shift }
    assert_equal "FINAL: Done", complete.fetch("content")
    assert_equal [2], delays
    assert_equal 2, @http.requests.length
    assert_equal 0, @http.finishes
    assert @http.started?
    assert_includes @log.string, "OpenRouter returned 429; retry 1/2 in 2s"
  end

  def test_body_reads_that_keep_making_progress_still_have_a_total_deadline
    response = success
    body = response.body
    response.define_singleton_method(:body) do
      body.chars.map { |character| sleep 0.002; character }.join
    end
    router(request_timeout: 0.03) { response }
    assert_raises(CodingAgent::Error) { complete }
    assert_equal 1, @http.finishes
    assert_equal 1, @http.requests.length
  end

  def test_progress_is_visible_during_a_slow_response
    # Exercise the real timed reporter, including its cleanup after a response.
    router(request_timeout: 10) { sleep 5.1; success }
    assert_equal "FINAL: Done", complete.fetch("content")
    assert_includes @log.string, "Still waiting for model response"
    assert_includes @log.string, "Model response received after"
  end

  def test_truncated_response_is_rejected_and_output_budget_can_be_overridden
    router(max_tokens: 2048) do
      FakeHTTPResponse.new(body: JSON.generate("choices" => [{ "finish_reason" => "length" }]))
    end
    error = assert_raises(CodingAgent::InvalidResponseError) { complete }
    assert_includes error.message, "2048-token output limit"
    assert_equal 2048, JSON.parse(@http.requests.first.body).fetch("max_tokens")
  end

  def test_interrupt_closes_the_connection_and_is_not_converted_to_a_retry
    router { raise Interrupt }
    assert_raises(Interrupt) { complete }
    assert_equal 1, @http.finishes
    assert_equal 1, @http.requests.length
    refute @http.started?
  end

  def test_invalid_deadlines_are_rejected
    [0, -1, Float::INFINITY, Float::NAN, "60"].each do |timeout|
      assert_raises(CodingAgent::Error) do
        CodingAgent::OpenRouter.new(api_key: "test-secret", request_timeout: timeout)
      end
    end
  end
end
