# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../examples/coding_agent/workspace"

class CodingAgentWorkspaceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("coding-agent-")
    @approvals = []
    @workspace = RubyUTCPAgent::Workspace.new(root: @root, approve: lambda { |name, details|
      @approvals << [name, details]
      true
    })
    File.write(File.join(@root, "hello.rb"), "puts 'old'\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def call(name, args = {})
    @workspace.call(name, args)
  end

  def digest(path = "hello.rb")
    call("read_file", "path" => path).fetch("sha256")
  end

  def test_read_has_content_and_revision_without_approval
    result = call("read_file", "path" => "hello.rb")
    assert_equal "puts 'old'\n", result["content"]
    assert_equal 64, result["sha256"].length
    assert_empty @approvals
  end

  def test_list_and_literal_search_ignore_secrets_and_generated_directories
    File.write(File.join(@root, ".env"), "SECRET=old")
    FileUtils.mkdir_p(File.join(@root, ".git"))
    File.write(File.join(@root, ".git", "config"), "old")
    assert_equal ["hello.rb"], call("list_files")["files"]
    result = call("search", "query" => "old")
    assert_equal "hello.rb", result["matches"][0]["path"]
    assert_equal 1, result["matches"].length
  end

  def test_new_file_and_existing_file_edits_need_approval
    result = call("write_file", "path" => "new.rb", "content" => "puts 1\n")
    assert result["changed"]
    assert_equal "puts 1\n", File.read(File.join(@root, "new.rb"))
    result = call("replace_text", "path" => "hello.rb", "old_text" => "old",
                 "new_text" => "new", "expected_sha256" => digest)
    assert result["changed"]
    assert_equal "puts 'new'\n", File.read(File.join(@root, "hello.rb"))
    assert_equal 2, @approvals.length
  end

  def test_stale_or_missing_revisions_do_not_overwrite
    assert_raises(ArgumentError) { call("write_file", "path" => "hello.rb", "content" => "bad") }
    assert_raises(ArgumentError) do
      call("write_file", "path" => "hello.rb", "content" => "bad", "expected_sha256" => "0" * 64)
    end
    assert_empty @approvals
    assert_equal "puts 'old'\n", File.read(File.join(@root, "hello.rb"))
  end

  def test_file_changed_during_approval_is_not_overwritten
    workspace = RubyUTCPAgent::Workspace.new(root: @root, approve: lambda { |_name, _details|
      File.write(File.join(@root, "hello.rb"), "human change")
      true
    })
    assert_raises(ArgumentError) do
      workspace.call("write_file", "path" => "hello.rb", "content" => "agent change", "expected_sha256" => digest)
    end
    assert_equal "human change", File.read(File.join(@root, "hello.rb"))
  end

  def test_denial_and_read_only_block_changes_and_commands
    deny = RubyUTCPAgent::Workspace.new(root: @root, approve: ->(*) { false })
    result = deny.call("write_file", "path" => "denied.rb", "content" => "no")
    assert_equal "denied", result["status"]
    refute File.exist?(File.join(@root, "denied.rb"))
    readonly = RubyUTCPAgent::Workspace.new(root: @root, approve: ->(*) { flunk "approval must not run" }, read_only: true)
    assert_equal "denied", readonly.call("run_command", "argv" => [RbConfig.ruby, "-e", "exit 0"])["status"]
    assert_equal "denied", readonly.call("write_file", "path" => "x", "content" => "x")["status"]
  end

  def test_path_escape_symlink_secret_and_hardlink_are_rejected
    ["../escape", "/etc/passwd", ".git/config", ".env", ".env.production"].each do |path|
      assert_raises(ArgumentError) { call("read_file", "path" => path) }
    end
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret"), "secret")
      File.symlink(outside, File.join(@root, "link"))
      assert_raises(ArgumentError) { call("read_file", "path" => "link/secret") }
    end
    File.link(File.join(@root, "hello.rb"), File.join(@root, "hard.rb"))
    assert_raises(ArgumentError) { call("read_file", "path" => "hard.rb") }
  end

  def test_replace_requires_exactly_one_match_and_noop_is_honest
    assert_raises(ArgumentError) do
      call("replace_text", "path" => "hello.rb", "old_text" => "missing", "new_text" => "x", "expected_sha256" => digest)
    end
    result = call("write_file", "path" => "hello.rb", "content" => "puts 'old'\n", "expected_sha256" => digest)
    refute result["changed"]
    assert_empty @approvals
  end

  def test_command_runs_argv_without_shell_expansion_and_reports_exit_status
    result = call("run_command", "argv" => [RbConfig.ruby, "-e", "puts ARGV[0]; exit 7", "$(touch oops)"])
    assert_equal 7, result["exit_status"]
    assert_includes result["output"], "$(touch oops)"
    refute File.exist?(File.join(@root, "oops"))
    assert_equal "run_command", @approvals.last[0]
  end

  def test_command_timeout_and_output_limit
    result = call("run_command", "argv" => [RbConfig.ruby, "-e", "sleep 5"], "timeout_seconds" => 1)
    assert result["timed_out"]
    result = call("run_command", "argv" => [RbConfig.ruby, "-e", "print 'x' * 100_000"])
    assert result["output_truncated"]
    assert_operator result["output"].bytesize, :<=, RubyUTCPAgent::Workspace::MAX_OUTPUT_BYTES
  end

  def test_command_does_not_inherit_provider_credentials
    previous = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "must-not-leak"
    result = call("run_command", "argv" => [RbConfig.ruby, "-e", "puts ENV.key?('OPENROUTER_API_KEY')"])
    assert_equal "false\n", result["output"]
  ensure
    ENV["OPENROUTER_API_KEY"] = previous
  end

  def test_unknown_tool_and_non_object_arguments_are_rejected
    assert_raises(ArgumentError) { call("delete_everything") }
    assert_raises(ArgumentError) { call("read_file", []) }
  end
end
