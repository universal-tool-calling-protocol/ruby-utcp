# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "stringio"
require_relative "../examples/coding_agent"

class CodingAgentTest < Minitest::Test
  # Stub only the remote HTTP exchange; use the real request builder, Code Mode,
  # and UTCP CLI tools.
  class ScriptedOpenRouter < CodingAgent::OpenRouter
    attr_reader :requests, :delays

    def initialize(responses, **options)
      @responses = responses
      @requests = []
      @delays = []
      super(api_key: "example-test-key", sleeper: ->(delay) { @delays << delay }, **options)
    end

    private

    def request_completion(request)
      @requests << { "body" => JSON.parse(request.body), "authorization" => request["Authorization"] }
      raise "Unexpected model request" if @responses.empty?

      response = @responses.shift
      response.respond_to?(:call) ? response.call : response
    end
  end

  def setup
    @workspace = Dir.mktmpdir("utcp coding $workspace ")
    @client = CodingAgent.create_client(workspace: @workspace)
    @output = StringIO.new
    @log = StringIO.new
  end

  def teardown
    @client.close
    FileUtils.remove_entry(@workspace)
  end

  def response(message, finish_reason: "stop")
    FakeHTTPResponse.new(body: JSON.generate("choices" => [{ "message" => message, "finish_reason" => finish_reason }]))
  end

  def tool_call(name, arguments, id: "call_1")
    { "id" => id, "type" => "function", "function" => {
      "name" => name, "arguments" => JSON.generate(arguments)
    } }
  end

  def code_call(code, id: "call_1")
    tool_call("execute_code", { code: code }, id: id)
  end

  def tool_response(*calls, **extra)
    response({ "role" => "assistant", "content" => nil, "tool_calls" => calls }.merge(extra))
  end

  def final_response(text = "Done.")
    response({ "role" => "assistant", "content" => text })
  end

  def code_response(code)
    response({ "role" => "assistant", "content" => "```ruby\n#{code}\n```" })
  end

  def agent(router, max_turns: 12, response_mode: :tools)
    CodingAgent::Agent.new(client: @client, openrouter: router, max_turns: max_turns, response_mode: response_mode, output: @output, log: @log)
  end

  def call(name, **arguments)
    @client.call_tool("workspace.#{name}", arguments)
  end

  def enable_shell
    @client.close
    @client = CodingAgent.create_client(workspace: @workspace, allow_shell: true)
  end

  def test_complete_coding_loop_discovers_and_composes_tools_through_code_mode
    enable_shell
    assert_instance_of UTCP::CodeModeUtcpClient, @client
    File.write(File.join(@workspace, "math.rb"), "def add(a, b)\n  a - b\nend\n")
    reasoning = [{ "type" => "reasoning.encrypted", "data" => "opaque-provider-state", "index" => 0 }]
    inspect_code = <<~RUBY
      files = codemode.call_tool("workspace.list_files", path: ".")
      source = codemode.call_tool("workspace.read_file", path: "math.rb", start_line: 1, max_lines: 200)
      puts "Read the addition implementation"
      { files: files, source: source }
    RUBY
    command = "#{Shellwords.escape(RbConfig.ruby)} -r ./math.rb -e 'abort \"wrong sum\" unless add(2, 3) == 5'"
    fix_code = <<~RUBY
      edit = codemode.call_tool("workspace.edit_file", path: "math.rb", old_text: "a - b", new_text: "a + b")
      if edit["error"]
        edit
      else
        command = <<~'COMMAND'
          #{command}
        COMMAND
        test = codemode.call_tool("workspace.run_command", command: command)
        { edit: edit, test: test }
      end
    RUBY
    router = ScriptedOpenRouter.new([
      tool_response(code_call("codemode.interfaces", id: "discover"), "reasoning_details" => reasoning),
      tool_response(code_call(inspect_code, id: "inspect")),
      tool_response(code_call(fix_code, id: "fix")),
      final_response("Fixed addition. The regression check passed.")
    ])

    agent(router).run("Fix addition and verify it")

    assert_equal "def add(a, b)\n  a + b\nend\n", File.read(File.join(@workspace, "math.rb"))
    assert_includes @output.string, "The regression check passed"
    assert_equal 4, router.requests.length
    first = router.requests.first
    assert_equal "Bearer example-test-key", first["authorization"]
    assert_equal "inclusionai/ling-3.0-flash", first["body"]["model"]
    refute first["body"]["provider"].key?("max_price")
    assert_equal true, first["body"].dig("provider", "require_parameters")
    assert_equal CodingAgent::OpenRouter::DEFAULT_MAX_TOKENS, first["body"]["max_tokens"]
    router.requests.each do |request|
      tools = request["body"]["tools"]
      assert_equal ["execute_code"], tools.map { |tool| tool["function"]["name"] }
      assert_equal ["code"], tools.first["function"]["parameters"]["required"]
    end
    transcript = router.requests.last["body"]["messages"]
    assert_equal reasoning, transcript[2]["reasoning_details"]
    results = transcript.select { |message| message["role"] == "tool" }
    assert_equal %w[discover inspect fix], results.map { |message| message["tool_call_id"] }
    results.each { |result| refute JSON.parse(result["content"]).key?("error") }
    assert_includes JSON.parse(results.first["content"])["result"], "workspace.read_file"
    assert_equal ["Read the addition implementation"], JSON.parse(results[1]["content"])["logs"]
    test_result = JSON.parse(results.last["content"]).dig("result", "test")
    assert_equal 0, test_result["exit_code"], test_result["output"]
    assert_includes @log.string, "[Code Mode 2: program]"
    assert_includes @log.string, inspect_code
    assert_includes @log.string, "[Tool 2.1: workspace.list_files arguments]"
    assert_includes @log.string, "[Tool 2.2: workspace.read_file output]"
    assert_includes @log.string, "[Tool 3.1: workspace.edit_file output]"
    assert_includes @log.string, "[Tool 3.2: workspace.run_command output]"
    assert_includes @log.string, "[Code Mode 2: captured logs]"
    assert_includes @log.string, "Read the addition implementation"
    assert_includes @log.string, "[Code Mode 3: result]"
  end

  def test_trace_shows_discarded_tool_outputs_search_results_and_stream_chunks
    File.write(File.join(@workspace, "trace.txt"), "intermediate output\n")
    code = <<~RUBY
      codemode.search_tools("read", limit: 1)
      codemode.call_tool_stream("workspace.read_file", path: "trace.txt", start_line: 1, max_lines: 1)
      "Only a summary is returned"
    RUBY
    router = ScriptedOpenRouter.new([tool_response(code_call(code)), final_response])
    agent(router).run("Inspect")
    execution = JSON.parse(router.requests.last["body"]["messages"].last["content"])
    assert_equal "Only a summary is returned", execution["result"]
    assert_includes @log.string, "[Tool 1.1: codemode.search_tools output]"
    assert_includes @log.string, '"name": "workspace.read_file"'
    assert_includes @log.string, "[Tool 1.2: workspace.read_file chunk]"
    assert_includes @log.string, "intermediate output"
    assert_includes @log.string, '"total_lines": 1'
  end

  def test_file_contents_and_paths_are_literal_cli_arguments
    name = "nested/$(touch escaped); quote's.rb"
    content = "# café\n" + 'puts "${TOKEN} $(touch escaped) `touch escaped` \\n"' + "\n"

    refute call("write_file", path: name, content: content).key?("error")
    assert_equal content, File.read(File.join(@workspace, name))
    refute File.exist?(File.join(@workspace, "escaped"))
    read = call("read_file", path: name, start_line: 2, max_lines: 1)
    assert_equal "2: #{content.lines.last}", read["content"]
    assert_nil read["next_line"]
    refute call("edit_file", path: name, old_text: "café", new_text: "tea").key?("error")
    assert_equal content.sub("café", "tea"), File.read(File.join(@workspace, name))
  end

  def test_code_mode_heredocs_preserve_generated_source_quotes_and_newlines
    code = <<~'RUBY'
      content = <<~'SOURCE'
        # café
        puts "Hello\nRuby"
        # ${TOKEN} $(touch escaped) `touch escaped` #{interpolation}
      SOURCE
      codemode.call_tool("workspace.write_file", path: "hello.rb", content: content)
    RUBY
    expected = <<~'SOURCE'
      # café
      puts "Hello\nRuby"
      # ${TOKEN} $(touch escaped) `touch escaped` #{interpolation}
    SOURCE
    router = ScriptedOpenRouter.new([tool_response(code_call(code)), final_response])
    agent(router).run("Create a hello world script")
    assert_equal expected, File.read(File.join(@workspace, "hello.rb"))
    refute File.exist?(File.join(@workspace, "escaped"))
    result = JSON.parse(router.requests.last["body"]["messages"].last["content"])
    refute result.key?("error")
  end

  def test_file_tools_reject_traversal_siblings_and_symlinks
    Dir.mktmpdir("utcp outside") do |outside|
      File.write(File.join(outside, "secret.txt"), "outside content")
      File.symlink(outside, File.join(@workspace, "link"))
      File.symlink(File.join(outside, "missing"), File.join(@workspace, "dangling"))
      ["../escape", @workspace + "-sibling/file", File.join(outside, "secret.txt"), "link/new.txt", "dangling"].each do |path|
        assert call("write_file", path: path, content: "do not write").key?("error"), path
      end
      assert call("read_file", path: "link/secret.txt", start_line: 1, max_lines: 1).key?("error")
      assert call("edit_file", path: "link/secret.txt", old_text: "outside", new_text: "changed").key?("error")
      assert_equal "outside content", File.read(File.join(outside, "secret.txt"))
      refute File.exist?(File.join(outside, "new.txt"))
      refute File.exist?(File.join(outside, "missing"))
    end
    assert call("write_file", path: ".git/config", content: "config").key?("error")
    refute File.exist?(File.join(@workspace, ".git"))
  end

  def test_edits_require_unique_nonempty_matches_and_writes_refuse_overwrites
    File.write(File.join(@workspace, "existing.rb"), "same same\n")
    ["", "absent", "same"].each do |old_text|
      assert call("edit_file", path: "existing.rb", old_text: old_text, new_text: "changed").key?("error")
    end
    assert call("write_file", path: "existing.rb", content: "overwritten").key?("error")
    assert_equal "same same\n", File.read(File.join(@workspace, "existing.rb"))
  end

  def test_reads_are_paged_and_reject_binary_oversized_or_excessive_output
    File.write(File.join(@workspace, "lines.txt"), "one\ntwo\nthree\n")
    first = call("read_file", path: "lines.txt", start_line: 1, max_lines: 2)
    assert_equal "1: one\n2: two\n", first["content"]
    assert_equal 3, first["next_line"]
    assert_equal 3, first["total_lines"]
    assert call("read_file", path: "lines.txt", start_line: 0, max_lines: 2).key?("error")
    File.binwrite(File.join(@workspace, "binary"), "\xFF\0".b)
    File.binwrite(File.join(@workspace, "huge"), "a" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1))
    File.write(File.join(@workspace, "long-line"), "a" * CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES)
    %w[binary huge long-line].each do |path|
      assert call("read_file", path: path, start_line: 1, max_lines: 200).key?("error"), path
    end
  end

  def test_read_file_accepts_50000_lines_and_returns_continuation_at_the_byte_limit
    File.write(File.join(@workspace, "many-lines.txt"), "x\n" * 50_000)
    tool = @client.list_tools.find { |item| item.name == "workspace.read_file" }
    assert_equal 50_000, tool.inputs.to_h.dig("properties", "max_lines", "maximum")
    first = call("read_file", path: "many-lines.txt", start_line: 1, max_lines: 50_000)
    refute first.key?("error")
    assert_equal 50_000, first["total_lines"]
    assert first["truncated"]
    assert_operator first["content"].bytesize, :<=, CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES
    assert_equal first["returned_lines"] + 1, first["next_line"]
    second = call("read_file", path: "many-lines.txt", start_line: first["next_line"], max_lines: 50_000)
    assert second["content"].start_with?("#{first['next_line']}: x\n")
    assert_equal first["sha256"], second["sha256"]
    last = call("read_file", path: "many-lines.txt", start_line: 49_999, max_lines: 50_000)
    assert_equal "49999: x\n50000: x\n", last["content"]
    assert_nil last["next_line"]
    refute last["truncated"]
    assert call("read_file", path: "many-lines.txt", start_line: 1, max_lines: 50_001).key?("error")
  end

  def test_disabled_shell_unknown_tools_and_invalid_code_arguments_return_errors_to_model
    refute_includes @client.list_tools.map(&:name), "workspace.run_command"
    router = ScriptedOpenRouter.new([
      tool_response(code_call('codemode.call_tool("workspace.run_command", command: "touch escaped")', id: "disabled"),
                    tool_call("workspace_write_file", { path: "bad.txt", content: "no" }, id: "unknown"),
                    tool_call("execute_code", {}, id: "missing"),
                    tool_call("execute_code", { code: 123 }, id: "type")),
      final_response("The calls failed.")
    ])

    agent(router).run("Inspect the project")

    results = router.requests.last["body"]["messages"].select { |message| message["role"] == "tool" }
    assert_equal 4, results.length
    results.each { |result| assert JSON.parse(result["content"]).key?("error") }
    refute File.exist?(File.join(@workspace, "bad.txt"))
    refute File.exist?(File.join(@workspace, "escaped"))
  end

  def test_code_mode_rejects_direct_process_file_access_and_unbounded_loops
    router = ScriptedOpenRouter.new([
      tool_response(code_call('File.write("escaped", "oops")', id: "filesystem"),
                    code_call('system("touch escaped")', id: "process"),
                    code_call("while true\nend", id: "loop")),
      final_response("The unsafe programs were rejected.")
    ])
    agent(router).run("Inspect")
    results = router.requests.last["body"]["messages"].select { |message| message["role"] == "tool" }
    results.each { |result| assert JSON.parse(result["content"]).key?("error") }
    assert_match(/step/i, JSON.parse(results.last["content"])["error"])
    refute File.exist?(File.join(@workspace, "escaped"))
  end

  def test_code_mode_errors_preserve_logs_and_warn_about_completed_effects
    code = <<~RUBY
      codemode.call_tool("workspace.write_file", path: "created.txt", content: "created")
      puts "Created the file"
      codemode.call_tool("workspace.missing")
    RUBY
    router = ScriptedOpenRouter.new([tool_response(code_call(code)), final_response])
    agent(router).run("Create a file")
    result = JSON.parse(router.requests.last["body"]["messages"].last["content"])
    assert result.key?("error")
    assert_equal ["Created the file"], result["logs"]
    assert_includes result["note"], "Earlier tool effects may have completed"
    assert_equal "created", File.read(File.join(@workspace, "created.txt"))
    assert_includes @log.string, "[Tool 1.1: workspace.write_file output]"
    assert_includes @log.string, "[Tool 1.2: workspace.missing error]"
    assert_includes @log.string, "[Code Mode request error]"
    assert_includes @log.string, "Created the file"
  end

  def test_shell_reports_failures_and_bounds_output_without_inheriting_api_key
    enable_shell
    previous_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-only-secret"
    result = call("run_command", command: 'printf "%s" "${OPENROUTER_API_KEY-unset}"; printf " failure" >&2; exit 7')
    assert_equal "unset failure", result["output"]
    assert_equal 7, result["exit_code"]
    refute result["truncated"]

    large = call("run_command", command: "#{Shellwords.escape(RbConfig.ruby)} -e 'print \"x\" * 100000'")
    assert_equal CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES, large["output"].bytesize
    assert large["truncated"]
    assert_equal 0, large["exit_code"]
  ensure
    ENV["OPENROUTER_API_KEY"] = previous_key
  end

  def test_turn_limit_stops_a_loop_without_claiming_completion
    router = ScriptedOpenRouter.new(Array.new(2) { tool_response(code_call("codemode.interfaces")) })
    error = assert_raises(CodingAgent::Error) { agent(router, max_turns: 2).run("Inspect") }
    assert_includes error.message, "Stopped after 2 turns"
    assert_equal 2, router.requests.length
    assert_empty @output.string
  end

  def test_invalid_tool_call_envelope_stops_before_any_tool_executes
    write = code_call('codemode.call_tool("workspace.write_file", path: "should-not-exist", content: "oops")')
    router = ScriptedOpenRouter.new([tool_response(write, write)])
    assert_raises(CodingAgent::Error) { agent(router).run("Inspect") }
    refute File.exist?(File.join(@workspace, "should-not-exist"))
  end

  def test_model_selection_accepts_paid_models_and_preserves_routing_variants
    [nil, "", " "].each do |model|
      assert_raises(CodingAgent::Error) { CodingAgent::OpenRouter.new(api_key: "test", model: model) }
    end
    assert_raises(CodingAgent::Error) { CodingAgent::OpenRouter.new(api_key: " ") }
    assert_raises(CodingAgent::Error) { CodingAgent::OpenRouter.new(api_key: "test", max_tokens: 0) }
    %w[inclusionai/ling-3.0-flash openrouter/auto provider/model provider/model:nitro].each do |model|
      router = ScriptedOpenRouter.new([final_response], model: model, max_tokens: 8192)
      agent(router).run("Explain the project")
      assert_equal model, router.requests.first["body"]["model"]
      assert_equal 8192, router.requests.first["body"]["max_tokens"]
      refute router.requests.first["body"]["provider"].key?("max_price")
    end
  end

  def test_paid_model_errors_explain_credits_and_endpoint_selection
    insufficient = ScriptedOpenRouter.new([FakeHTTPResponse.new(code: 402)])
    error = assert_raises(CodingAgent::Error) { agent(insufficient).run("Explain") }
    assert_includes error.message, "Insufficient credits"
    missing = ScriptedOpenRouter.new([FakeHTTPResponse.new(code: 404)], model: "provider/chosen-model")
    error = assert_raises(CodingAgent::Error) { agent(missing).run("Explain") }
    assert_includes error.message, "provider/chosen-model"
    refute_includes error.message, "free"
  end

  def test_truncated_tool_json_is_discarded_before_any_calls_run_or_enter_history
    File.write(File.join(@workspace, "README.md"), "Original README\n")
    valid = code_call('codemode.call_tool("workspace.write_file", path: "must-not-run", content: "partial")', id: "valid")
    cut_off = code_call("", id: "truncated")
    cut_off["function"]["arguments"] = '{"code":"' + ("large README rewrite " * 1000)[0, 16_007]
    recovery = code_call('codemode.call_tool("workspace.edit_file", path: "README.md", old_text: "Original", new_text: "Updated")')
    router = ScriptedOpenRouter.new([tool_response(valid, cut_off), tool_response(recovery), final_response])

    agent(router).run("Rewrite README")

    refute File.exist?(File.join(@workspace, "must-not-run"))
    assert_equal "Updated README\n", File.read(File.join(@workspace, "README.md"))
    retry_messages = router.requests[1]["body"]["messages"]
    refute retry_messages.any? { |message| message["role"] == "assistant" }
    refute_includes JSON.generate(retry_messages), "large README rewrite"
    assert_includes retry_messages.last["content"], "No tools from that response were executed"
    assert_includes retry_messages.last["content"], "smaller"
    assert_includes @log.string, "Recovering"
  end

  def test_http_200_provider_failure_is_retried_without_losing_conversation
    failure = FakeHTTPResponse.new(body: JSON.generate(error: {
      code: 502, message: "Provider disconnected during generation", metadata: { provider_name: "ExampleProvider" }
    }))
    router = ScriptedOpenRouter.new([failure, final_response])
    agent(router).run("Rewrite README")
    assert_equal 2, router.requests.length
    assert_equal [2], router.delays
    assert_equal router.requests.first, router.requests.last
  end

  def test_provider_errors_include_reason_code_provider_and_request_id
    failure = FakeHTTPResponse.new(body: JSON.generate(id: "gen-example", error: {
      code: 400, message: "Invalid tool arguments", metadata: { provider_name: "ExampleProvider", error_type: "invalid_request" }
    }))
    router = ScriptedOpenRouter.new([failure])
    error = assert_raises(CodingAgent::Error) { agent(router).run("Rewrite README") }
    %w[400 ExampleProvider gen-example invalid_request].each { |detail| assert_includes error.message, detail }
    assert_includes error.message, "Invalid tool arguments"
    assert_empty router.delays
  end

  def test_long_readme_rewrite_uses_small_draft_chunks_and_commits_at_the_end
    original = "# Original README\n\n" + "Keep the original intact until the complete draft is ready.\n" * 300
    target = File.join(@workspace, "README.md")
    File.write(target, original)
    File.chmod(0o640, target)
    fingerprint = Digest::SHA256.hexdigest(original)
    chunks = Array.new(4) do |index|
      "## Section #{index + 1}\n\n" + ("Café documentation with `code`, \"quotes\", and $variables.\n" * 100)
    end
    responses = [tool_response(code_call('codemode.call_tool("workspace.read_file", path: "README.md", start_line: 1, max_lines: 200)'))]
    total_bytes = 0
    chunks.each_with_index do |chunk, index|
      method = index.zero? ? "write_file" : "append_file"
      size_argument = index.zero? ? "" : ", expected_bytes: #{total_bytes}"
      code = "chunk = <<~'README_CHUNK'\n#{chunk}README_CHUNK\n" \
             "codemode.call_tool(\"workspace.#{method}\", path: \"README.md.draft\", content: chunk#{size_argument})"
      responses << lambda do
        assert_equal original, File.read(target)
        tool_response(code_call(code, id: "chunk_#{index}"))
      end
      total_bytes += chunk.bytesize
    end
    responses << lambda do
      assert_equal original, File.read(target)
      assert_equal chunks.join, File.read(File.join(@workspace, "README.md.draft"))
      tool_response(code_call("codemode.call_tool(\"workspace.commit_file\", path: \"README.md\", " \
                              "draft_path: \"README.md.draft\", expected_sha256: \"#{fingerprint}\")", id: "commit"))
    end
    responses << final_response("README rewritten.")
    router = ScriptedOpenRouter.new(responses)

    agent(router).run("Rewrite README")

    assert_equal chunks.join, File.read(target)
    assert_equal 0o640, File.stat(target).mode & 0o777
    refute File.exist?(File.join(@workspace, "README.md.draft"))
    assert_includes @log.string, "workspace.append_file output"
    assert_includes @log.string, "workspace.commit_file output"
    transcript = router.requests.last["body"]["messages"]
    transcript.select { |message| message["role"] == "tool" }.each do |message|
      execution = JSON.parse(message["content"])
      refute execution.key?("error"), message["content"]
      refute execution["result"].key?("error"), message["content"]
    end
  end

  def test_default_code_replies_rewrite_large_markdown_without_tool_argument_json
    original = "# Original README\n"
    target = File.join(@workspace, "README.md")
    File.write(target, original)
    fingerprint = Digest::SHA256.hexdigest(original)
    paragraph = <<~'MARKDOWN'
      ## Quoted examples

      Café, "quotes", backslashes, and `inline code` stay literal.

      ```ruby
      puts "hello\nworld"
      # ${TOKEN} $(touch escaped) #{interpolation}
      ```

      ```json
      {"path":"a\\b", "quoted":"\"hello\""}
      ```

    MARKDOWN
    replacement = "# Rewritten README\n\n" + paragraph * 150
    assert_operator replacement.bytesize, :>, 27_049
    code = "content = <<~'README_BODY'\n#{replacement}README_BODY\n" + <<~RUBY
      draft = codemode.call_tool("workspace.write_file", path: "README.md.draft", content: content)
      if draft["error"]
        draft
      else
        codemode.call_tool("workspace.commit_file", path: "README.md", draft_path: "README.md.draft", expected_sha256: "#{fingerprint}")
      end
    RUBY
    router = ScriptedOpenRouter.new([
      code_response("codemode.interfaces"),
      code_response('codemode.call_tool("workspace.read_file", path: "README.md", start_line: 1, max_lines: 50000)'),
      code_response(code), final_response("FINAL: README rewritten.")
    ])

    CodingAgent::Agent.new(client: @client, openrouter: router, output: @output, log: @log).run("Rewrite README")

    assert_equal replacement, File.read(target)
    refute File.exist?(File.join(@workspace, "escaped"))
    assert_equal "README rewritten.\n", @output.string
    router.requests.each do |request|
      refute request["body"].key?("tools")
      refute request["body"].key?("tool_choice")
      request["body"]["messages"].each do |message|
        refute message.key?("tool_calls")
        refute_equal "tool", message["role"]
      end
    end
    assert_includes @log.string, "workspace.commit_file output"
    results = router.requests.last["body"]["messages"].select do |message|
      message["content"].to_s.start_with?("Code Mode execution result (data):")
    end
    results.each do |message|
      execution = JSON.parse(message["content"].split("\n", 2).last)
      refute execution.key?("error"), message["content"]
    end
  end

  def test_incomplete_code_replies_are_rejected_before_execution_and_removed_from_history
    bad = 'codemode.call_tool("workspace.write_file", path: "must-not-run", content: "oops")'
    router = ScriptedOpenRouter.new([
      final_response("```ruby\n#{bad}"),
      code_response("#{bad}\ncontent = <<~'README'\nUnfinished document"),
      code_response('codemode.call_tool("workspace.write_file", path: "complete.txt", content: "done")'),
      final_response("FINAL: Done.")
    ])
    agent(router, response_mode: :code).run("Create a file")
    refute File.exist?(File.join(@workspace, "must-not-run"))
    assert_equal "done", File.read(File.join(@workspace, "complete.txt"))
    history = router.requests.last["body"]["messages"]
    refute_includes JSON.generate(history), "must-not-run"
    assert_includes @log.string, "Recovering"
    assert_equal "Done.\n", @output.string
  end

  def test_code_replies_still_use_the_constrained_interpreter_and_final_reports_are_not_executed
    router = ScriptedOpenRouter.new([
      code_response('system("touch escaped")'),
      final_response("FINAL: Rejected direct process access.\n```ruby\nsystem(\"touch escaped\")\n```")
    ])
    agent(router, response_mode: :code).run("Inspect")
    refute File.exist?(File.join(@workspace, "escaped"))
    result = JSON.parse(router.requests.last["body"]["messages"].last["content"].split("\n", 2).last)
    assert result.key?("error")
    assert_includes @log.string, "Code Mode request error"
    assert_includes @output.string, "Rejected direct process access"
  end

  def test_draft_append_guards_duplicates_size_and_workspace_paths
    created = call("write_file", path: "README.md.draft", content: "# Café\n")
    assert_equal "# Café\n".bytesize, created["total_bytes"]
    appended = call("append_file", path: "README.md.draft", content: "More text\n", expected_bytes: created["total_bytes"])
    assert_equal "# Café\nMore text\n".bytesize, appended["total_bytes"]
    assert call("append_file", path: "README.md.draft", content: "More text\n", expected_bytes: created["total_bytes"]).key?("error")
    assert_equal "# Café\nMore text\n", File.read(File.join(@workspace, "README.md.draft"))
    assert call("append_file", path: "../outside", content: "no", expected_bytes: 0).key?("error")

    File.binwrite(File.join(@workspace, "full.draft"), "a" * CodingAgent::WorkspaceTools::MAX_FILE_BYTES)
    assert call("append_file", path: "full.draft", content: "x", expected_bytes: CodingAgent::WorkspaceTools::MAX_FILE_BYTES).key?("error")
    assert_equal CodingAgent::WorkspaceTools::MAX_FILE_BYTES, File.size(File.join(@workspace, "full.draft"))
  end

  def test_commit_rejects_stale_original_and_symlink_drafts_without_changing_files
    target = File.join(@workspace, "README.md")
    File.write(target, "Original\n")
    snapshot = call("read_file", path: "README.md", start_line: 1, max_lines: 1)
    call("write_file", path: "README.md.draft", content: "Rewritten\n")
    File.write(target, "Changed by user\n")
    rejected = call("commit_file", path: "README.md", draft_path: "README.md.draft", expected_sha256: snapshot["sha256"])
    assert_includes rejected["error"], "Original file changed"
    assert_equal "Changed by user\n", File.read(target)
    assert_equal "Rewritten\n", File.read(File.join(@workspace, "README.md.draft"))
    File.symlink("README.md.draft", File.join(@workspace, "linked.draft"))
    current_hash = Digest::SHA256.file(target).hexdigest
    assert call("commit_file", path: "README.md", draft_path: "linked.draft", expected_sha256: current_hash).key?("error")
    assert call("commit_file", path: "README.md", draft_path: "README.md", expected_sha256: current_hash).key?("error")
    assert_equal "Changed by user\n", File.read(target)
  end

  def test_invalid_ruby_batch_and_reported_output_truncation_recover_without_side_effects
    valid = code_call('codemode.call_tool("workspace.write_file", path: "must-not-run", content: "no")', id: "valid")
    incomplete = code_call("content = <<~'README'\nUnfinished document", id: "incomplete")
    truncated = response({ "role" => "assistant", "tool_calls" => [valid] }, finish_reason: "length")
    router = ScriptedOpenRouter.new([tool_response(valid, incomplete), truncated, final_response("Retry succeeded.")])
    agent(router).run("Rewrite README")
    refute File.exist?(File.join(@workspace, "must-not-run"))
    assert_equal 3, router.requests.length
    messages = router.requests.last["body"]["messages"]
    assert_equal %w[system user user], messages.map { |message| message["role"] }
    assert_includes messages.last["content"], "#{CodingAgent::OpenRouter::DEFAULT_MAX_TOKENS}-token output limit"
    refute_includes JSON.generate(messages), "Unfinished document"
  end

  def test_invalid_response_recovery_is_bounded_and_does_not_accumulate_bad_history
    invalid = code_call("")
    invalid["function"]["arguments"] = '{"code":"unfinished'
    router = ScriptedOpenRouter.new(Array.new(3) { tool_response(invalid) })
    error = assert_raises(CodingAgent::Error) { agent(router).run("Rewrite README") }
    assert_includes error.message, "Stopped after 3 invalid model responses"
    assert_equal 3, router.requests.length
    assert_equal 3, router.requests.last["body"]["messages"].length
    refute_includes JSON.generate(router.requests), "unfinished"
  end

  def test_api_error_messages_redact_authorization_credentials
    failure = FakeHTTPResponse.new(code: 401, body: JSON.generate(error: { code: 401, message: "Bad key: example-test-key" }))
    error = assert_raises(CodingAgent::APIError) { agent(ScriptedOpenRouter.new([failure])).run("Inspect") }
    assert_includes error.message, "[REDACTED]"
    refute_includes error.message, "example-test-key"
  end

  def test_openrouter_retries_transient_errors_with_bounded_delays
    router = ScriptedOpenRouter.new([
      FakeHTTPResponse.new(code: 429, headers: { "Retry-After" => "999" }),
      FakeHTTPResponse.new(code: 503), final_response
    ])
    agent(router).run("Explain")
    assert_equal [30, 4], router.delays
    assert_equal 3, router.requests.length
    assert_equal router.requests.first, router.requests.last
  end

  def test_openrouter_stops_after_retries_and_reports_authentication_errors
    router = ScriptedOpenRouter.new(Array.new(3) { FakeHTTPResponse.new(code: 429) })
    error = assert_raises(CodingAgent::Error) { agent(router).run("Explain") }
    assert_includes error.message, "quota or rate limit"
    assert_equal 3, router.requests.length
    unauthorized = ScriptedOpenRouter.new([FakeHTTPResponse.new(code: 401, body: "not JSON")])
    error = assert_raises(CodingAgent::Error) { agent(unauthorized).run("Explain") }
    assert_includes error.message, "OPENROUTER_API_KEY"
    assert_empty unauthorized.delays
  end

  def test_unusable_model_responses_fail_and_incomplete_responses_have_bounded_recovery
    bad_responses = [
      FakeHTTPResponse.new(body: "not JSON"),
      FakeHTTPResponse.new(body: '{"error":{"message":"provider failed"}}'),
      FakeHTTPResponse.new(body: '{"choices":[]}'),
      response({ "role" => "assistant", "content" => "partial" }, finish_reason: "length"),
      response({ "role" => "assistant", "content" => nil })
    ]
    bad_responses.each do |bad|
      assert_raises(CodingAgent::Error) { agent(ScriptedOpenRouter.new([bad, bad, bad])).run("Explain") }
    end
  end

  def test_connection_errors_have_actionable_messages
    router = ScriptedOpenRouter.new([])
    router.define_singleton_method(:request_completion) { |_request| raise Net::ReadTimeout }
    error = assert_raises(CodingAgent::Error) { agent(router).run("Explain") }
    assert_includes error.message, "connection failed"
  end

  def test_cli_help_and_input_validation_work_without_network
    assert_equal 0, CodingAgent.run_cli(["--help"], env: {}, output: @output, log: @log)
    assert_includes @output.string, "--allow-shell"
    assert_equal 1, CodingAgent.run_cli(["task"], env: {}, output: @output, log: @log)
    assert_includes @log.string, "OPENROUTER_API_KEY"
    assert_equal 1, CodingAgent.run_cli(["--max-turns", "0", "task"], env: {}, output: @output, log: @log)
    assert_equal 1, CodingAgent.run_cli([], env: {}, output: @output, log: @log)
    assert_equal 1, CodingAgent.run_cli(["--bogus"], env: {}, output: @output, log: @log)
  end

  def test_initial_interfaces_allow_search_read_and_batch_edit_without_discovery_or_shell
    File.write(File.join(@workspace, "math.rb"), "def add(a, b)\n  a - b\nend\n")
    router = ScriptedOpenRouter.new([
      code_response(<<~'RUBY'),
        matches = codemode.call_tool("workspace.search_files", path: ".", query: "def add", glob: "*.rb", offset: 0)
        source = codemode.call_tool("workspace.read_files", files: [{path: matches["matches"][0]["path"]}])
        file = source["files"][0]
        codemode.call_tool("workspace.edit_file_batch", path: file["path"], expected_sha256: file["sha256"],
          edits: [{old_text: "a - b", new_text: "a + b"}, {old_text: "def add", new_text: "def sum"}])
      RUBY
      final_response("FINAL: Fixed the implementation. Tests were not run.")
    ])
    agent(router, response_mode: :code).run("Fix and rename addition")
    assert_equal "def sum(a, b)\n  a + b\nend\n", File.read(File.join(@workspace, "math.rb"))
    assert_equal 2, router.requests.length
    prompt = router.requests.first["body"]["messages"].first["content"]
    assert_includes prompt, 'codemode.call_tool("workspace.search_files", path:, query:, glob:, offset:)'
    assert_includes prompt, 'codemode.call_tool("workspace.read_files", files:)'
    refute_includes prompt, 'codemode.call_tool("workspace.run_command"'
    assert_includes @log.string, "[Tool 1.3: workspace.edit_file_batch output]"
  end

  def test_find_files_recurses_with_globs_and_stable_pagination
    FileUtils.mkdir_p(File.join(@workspace, "lib/nested"))
    File.write(File.join(@workspace, "root.rb"), "root")
    File.write(File.join(@workspace, "lib/nested/target.rb"), "target")
    File.write(File.join(@workspace, "lib/nested/notes.txt"), "notes")
    expected = ["lib/nested/target.rb", "root.rb"]
    %w[*.rb **/*.rb].each do |glob|
      result = call("find_files", path: ".", glob: glob, offset: 0)
      assert_equal expected, result["files"], result.inspect
      refute result["truncated"]
      assert_nil result["next_offset"]
    end
    assert_equal [expected.first], call("find_files", path: "lib", glob: "nested/*.rb", offset: 0)["files"]
    205.times { |number| File.write(File.join(@workspace, format("file%03d.txt", number)), "") }
    first = call("find_files", path: ".", glob: "file*.txt", offset: 0)
    assert_equal 200, first["files"].length
    assert_equal 200, first["next_offset"]
    assert first["truncated"]
    second = call("find_files", path: ".", glob: "file*.txt", offset: first["next_offset"])
    assert_equal (0...205).map { |number| format("file%03d.txt", number) }, first["files"] + second["files"]
    refute second["truncated"]
    assert_nil second["next_offset"]
  end

  def test_search_is_literal_and_reports_line_numbers_excerpts_and_skipped_files
    FileUtils.mkdir_p(File.join(@workspace, "src"))
    File.write(File.join(@workspace, "src/code.rb"), "needle-anything\nneedle.* café\n" + "é" * 2000 + "needle.* end\n")
    File.binwrite(File.join(@workspace, "binary.rb"), "needle.*\0")
    File.binwrite(File.join(@workspace, "large.rb"), "x" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1))
    result = call("search_files", path: ".", query: "needle.*", glob: "*.rb", offset: 0)
    assert_equal [2, 3], result["matches"].map { |match| match["line"] }
    assert_equal ["src/code.rb"], result["matches"].map { |match| match["path"] }.uniq
    assert_equal "needle.* café", result["matches"][0]["text"]
    refute result["matches"][0]["text_truncated"]
    assert_includes result["matches"][1]["text"], "needle.* end"
    assert result["matches"][1]["text"].valid_encoding?
    assert result["matches"][1]["text_truncated"]
    assert_equal 2, result["skipped_files"]
    refute result["scan_truncated"]
  end

  def test_search_pages_respect_the_serialized_byte_budget_without_losing_matches
    File.write(File.join(@workspace, "quoted.txt"), ("needle " + '"' * 990 + "\n") * 45)
    lines = []
    offset = 0
    loop do
      result = call("search_files", path: ".", query: "needle", glob: "*.txt", offset: offset)
      assert_operator JSON.generate(result["matches"]).bytesize, :<=, CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES
      lines.concat(result["matches"].map { |match| match["line"] })
      break unless result["next_offset"]

      assert_operator result["next_offset"], :>, offset
      offset = result["next_offset"]
    end
    assert_equal (1..45).to_a, lines
  end

  def test_navigation_rejects_escape_paths_and_skips_symlinks_and_dependency_directories
    Dir.mktmpdir("utcp outside") do |outside|
      File.write(File.join(outside, "secret.rb"), "needle")
      File.symlink(outside, File.join(@workspace, "link"))
      File.symlink(File.join(outside, "secret.rb"), File.join(@workspace, "linked.rb"))
      CodingAgent::WorkspaceTools::HIDDEN_DIRECTORIES.each do |directory|
        FileUtils.mkdir_p(File.join(@workspace, directory))
        File.write(File.join(@workspace, directory, "hidden.rb"), "needle")
      end
      assert_empty call("find_files", path: ".", glob: "**/*", offset: 0)["files"]
      assert_empty call("search_files", path: ".", query: "needle", glob: "**/*", offset: 0)["matches"]
      ["../", "link", ".git", outside].each do |path|
        assert call("find_files", path: path, glob: "**/*", offset: 0).key?("error"), path
        assert call("search_files", path: path, query: "needle", glob: "**/*", offset: 0).key?("error"), path
      end
    end
    assert call("find_files", path: ".", glob: "", offset: 0).key?("error")
    assert call("find_files", path: ".", glob: "**/*", offset: -1).key?("error")
    assert call("search_files", path: ".", query: "", glob: "**/*", offset: 0).key?("error")
  end

  def with_workspace_tool_limit(name, value)
    klass = CodingAgent::WorkspaceTools
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield CodingAgent::WorkspaceTools.new(@workspace)
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end

  def test_navigation_discloses_scan_limits_instead_of_claiming_no_matches
    File.write(File.join(@workspace, "a.txt"), "binary\0")
    File.write(File.join(@workspace, "b.txt"), "needle")
    with_workspace_tool_limit(:MAX_SCAN_ENTRIES, 1) do |tools|
      result = tools.search_files(".", "missing", "**/*", 0)
      assert_empty result["matches"]
      assert result["scan_truncated"]
      assert result["truncated"]
      assert_nil result["next_offset"]
      assert_equal 1, result["scanned_entries"]
    end
    with_workspace_tool_limit(:MAX_SEARCH_BYTES, 8) do |tools|
      result = tools.search_files(".", "needle", "**/*", 0)
      assert_empty result["matches"]
      assert result["scan_truncated"], "Binary reads must also consume the byte budget"
      assert_equal 1, result["skipped_files"]
    end
  end

  def test_batched_reads_share_budget_keep_per_file_errors_and_preserve_literal_paths
    paths = 8.times.map { |index| "page#{index}.txt" }
    paths.each { |path| File.write(File.join(@workspace, path), "café\n" * 2000) }
    result = call("read_files", files: paths.map { |path| { path: path, start_line: 2, max_lines: 2000 } })
    assert_equal paths, result["files"].map { |file| file["path"] }
    assert_operator result["files"].sum { |file| file["content"].bytesize }, :<=, CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES
    result["files"].each do |file|
      assert file["content"].start_with?("2: café\n")
      assert_equal file["returned_lines"] + 2, file["next_line"]
      assert_equal Digest::SHA256.file(File.join(@workspace, file["path"])).hexdigest, file["sha256"]
    end
    name = '$(touch escaped) quote".txt'
    File.write(File.join(@workspace, name), "literal")
    mixed = call("read_files", files: [{ path: "../outside" }, { path: name }, { path: name, max_lines: nil }])
    assert mixed["files"][0].key?("error")
    assert_equal "1: literal", mixed["files"][1]["content"]
    assert mixed["files"][2].key?("error")
    refute File.exist?(File.join(@workspace, "escaped"))
    assert call("read_files", files: []).key?("error")
    assert call("read_files", files: Array.new(9) { { path: name } }).key?("error")
  end

  def test_batch_edits_validate_every_edit_before_writing_and_guard_retries
    path = File.join(@workspace, "edit.rb")
    File.write(path, "alpha beta\n")
    File.chmod(0o751, path)
    sha256 = Digest::SHA256.file(path).hexdigest
    edits = [{ old_text: "alpha", new_text: "gamma" }, { old_text: "missing", new_text: "delta" }]
    result = call("edit_file_batch", path: "edit.rb", expected_sha256: sha256, edits: edits)
    assert_includes result["error"], "Edit 2"
    assert_equal "alpha beta\n", File.read(path)
    edits[1][:old_text] = "beta"
    result = call("edit_file_batch", path: "edit.rb", expected_sha256: sha256, edits: edits)
    assert_equal "gamma delta\n", File.read(path)
    assert_equal 2, result["edits_applied"]
    assert_equal Digest::SHA256.file(path).hexdigest, result["sha256"]
    assert_equal 0o751, File.stat(path).mode & 0o777
    assert_equal ["edit.rb"], Dir.children(@workspace)
    retry_result = call("edit_file_batch", path: "edit.rb", expected_sha256: sha256, edits: edits)
    assert_includes retry_result["error"], "File changed"
    assert_equal "gamma delta\n", File.read(path)
  end

  def test_batch_edits_reject_invalid_ambiguous_oversized_and_symlink_changes
    path = File.join(@workspace, "edit.txt")
    File.write(path, "same same\n")
    sha256 = Digest::SHA256.file(path).hexdigest
    [[], [{ old_text: "", new_text: "x" }], [{ old_text: "same", new_text: "x" }],
     [{ old_text: "same same", new_text: nil }],
     [{ old_text: "same same", new_text: "x" * CodingAgent::WorkspaceTools::MAX_FILE_BYTES }]].each do |edits|
      result = call("edit_file_batch", path: "edit.txt", expected_sha256: sha256, edits: edits)
      assert result.key?("error"), result.inspect
      assert_equal "same same\n", File.read(path)
    end
    File.symlink(path, File.join(@workspace, "link.txt"))
    assert call("edit_file_batch", path: "link.txt", expected_sha256: sha256,
                edits: [{ old_text: "same same", new_text: "changed" }]).key?("error")
    assert_equal "same same\n", File.read(path)
  end

  class FakePersistentHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :keep_alive_timeout
    attr_reader :starts, :finishes, :requests

    def initialize(responses)
      @responses = responses
      @starts = @finishes = 0
      @requests = []
      @started = false
    end

    def start
      @starts += 1
      @started = true
    end

    def started?
      @started
    end

    def finish
      @finishes += 1
      @started = false
    end

    def request(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  # Minitest 6 no longer bundles Object#stub. Keep constructor replacement local
  # to these offline tests and restore inherited constructors without shadowing.
  def with_constructor(klass, replacement)
    singleton = klass.singleton_class
    owned = singleton.instance_methods(false).include?(:new)
    original = singleton.instance_method(:new) if owned
    singleton.send(:remove_method, :new) if owned
    singleton.send(:define_method, :new, replacement)
    yield
  ensure
    singleton.send(:remove_method, :new)
    singleton.send(:define_method, :new, original) if owned
  end

  def test_openrouter_reuses_and_closes_its_http_connection
    http = FakePersistentHTTP.new([final_response, final_response])
    router = CodingAgent::OpenRouter.new(api_key: "test")
    with_constructor(Net::HTTP, ->(*) { http }) do
      2.times { router.complete(messages: [{ "role" => "user", "content" => "Inspect" }]) }
      assert_equal 1, http.starts
      assert_equal 2, http.requests.length
      assert_equal true, http.use_ssl
      assert_equal 120, http.keep_alive_timeout
      router.close
      router.close
      assert_equal 1, http.finishes
    end
  end

  def test_connection_failures_close_the_socket_and_allow_a_fresh_connection
    broken = FakePersistentHTTP.new([Net::ReadTimeout.new])
    healthy = FakePersistentHTTP.new([final_response])
    connections = [broken, healthy]
    router = CodingAgent::OpenRouter.new(api_key: "test")
    with_constructor(Net::HTTP, ->(*) { connections.shift }) do
      assert_raises(CodingAgent::Error) { router.complete(messages: []) }
      assert_equal 1, broken.finishes
      assert_equal "Done.", router.complete(messages: [])["content"]
      assert_equal 1, healthy.starts
      router.close
      assert_equal 1, healthy.finishes
    end
  end

  def test_cli_closes_the_router_on_success_and_failure
    [final_response("FINAL: Done."), -> { raise Net::ReadTimeout }].each do |response|
      router = ScriptedOpenRouter.new([response])
      closed = false
      router.define_singleton_method(:close) { closed = true }
      with_constructor(CodingAgent::OpenRouter, ->(*) { router }) do
        status = CodingAgent.run_cli(["--workspace", @workspace, "Inspect"], env: {}, output: @output, log: @log)
        assert_equal response.respond_to?(:call) ? 1 : 0, status
      end
      assert closed
    end
  end
end
