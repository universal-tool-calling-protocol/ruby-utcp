# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "json"

class CodingAgentUTCPTest < Minitest::Test
  def test_real_sdk_discovery_dispatch_codemode_approval_and_call_budget
    Dir.mktmpdir("coding-agent-sdk-") do |root|
      File.write(File.join(root, "hello.rb"), "puts 'old'\n")
      source = <<~'CODE'
        require "json"
        require "utcp"
        require_relative "examples/coding_agent/utcp_workspace"
        root = ARGV.fetch(0)
        workspace = RubyUTCPAgent::Workspace.new(root: root, approve: ->(*) { true })
        client = RubyUTCPAgent::WorkspaceClient.build(workspace)
        begin
          names = client.list_tools.map(&:name)
          raise "discovery mismatch" unless names.sort == RubyUTCPAgent::Workspace::OPERATIONS.map { |n| "workspace.#{n}" }.sort
          first = client.call_tool("workspace.read_file", { "path" => "hello.rb" })
          code = <<~'CHAIN'
            before = codemode.call_tool("workspace.read_file", {"path" => "hello.rb"})
            codemode.call_tool("workspace.replace_text", {
              "path" => "hello.rb", "old_text" => "old", "new_text" => "new",
              "expected_sha256" => before["sha256"]
            })
          CHAIN
          execution = UTCP::CodeMode.new(client).execute(code, timeout: 10)
          raise "Code Mode did not edit" unless execution["result"]["changed"]
          raise "wrong edit" unless File.read(File.join(root, "hello.rb")) == "puts 'new'\n"
          raise "search failed" if client.search_tools("read", limit: 5).empty?

          readonly = RubyUTCPAgent::Workspace.new(root: root, approve: ->(*) { raise "bypassed read-only" }, read_only: true)
          other = RubyUTCPAgent::WorkspaceClient.build(readonly)
          begin
            denied = UTCP::CodeMode.new(other).execute('codemode.call_tool("workspace.write_file", {"path" => "no.rb", "content" => "bad"})')
            raise "Code Mode bypassed policy" unless denied["result"]["status"] == "denied"
            raise "wrote despite denial" if File.exist?(File.join(root, "no.rb"))
            # A second client must not replace the first client's workspace/policy.
            allowed = client.call_tool("workspace.write_file", { "path" => "allowed.rb", "content" => "ok" })
            raise "clients interfered" unless allowed["changed"]
          ensure
            other.close
          end

          client.reset_budget(1)
          client.call_tool("workspace.list_files", {})
          begin
            client.call_tool("workspace.list_files", {})
            raise "budget did not stop execution"
          rescue UTCP::ToolCallError => error
            raise unless error.message.include?("budget")
          end
          puts JSON.generate("tools" => names.length, "initial_sha256" => first["sha256"], "codemode" => "passed")
        ensure
          client.close
        end
      CODE
      repo = File.expand_path("..", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", source, root, chdir: repo)
      assert status.success?, "Real SDK integration failed:\n#{stdout}\n#{stderr}"
      result = JSON.parse(stdout)
      assert_equal 6, result["tools"]
      assert_equal "passed", result["codemode"]
    end
  end
end
