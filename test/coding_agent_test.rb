# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../examples/coding_agent"

class CodingAgentTest < Minitest::Test
  class ScriptedRouter
    attr_reader :requests, :closed

    def initialize(*responses, &handler)
      @responses = responses
      @handler = handler
      @requests = []
    end

    def complete(messages:, tools:)
      @requests << { messages: Marshal.load(Marshal.dump(messages)), tools: tools }
      @handler ? @handler.call(messages, tools) : @responses.shift
    end

    def close
      @closed = true
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir("coding agent ' workspace"))
    @workspace = CodingAgent::WorkspaceTools.new(@root)
    @output = StringIO.new
    @log = StringIO.new
  end

  def teardown
    @client.close if @client
    FileUtils.remove_entry(@root)
  end

  def write(path, content)
    full_path = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.binwrite(full_path, content)
  end

  def contents(path)
    File.read(File.join(@root, path))
  end

  def snapshot(**options)
    CodingAgent::RepositoryContext.new(@root, **options).build
  end

  def guarded_client(allow_shell: false)
    @client = CodingAgent.create_client(workspace: @root, allow_shell: allow_shell)
    CodingAgent::Agent.new(client: @client, openrouter: ScriptedRouter.new, output: @output, log: @log)
    @client
  end

  # Minitest 6 keeps mocking in a separate gem. These two constructors are
  # inherited from Class, so removing the temporary method restores them.
  def with_constructor(klass, instance)
    calls = []
    klass.define_singleton_method(:new) do |*_arguments, **options|
      calls << options
      instance
    end
    yield calls
  ensure
    klass.singleton_class.remove_method(:new)
  end

  def git(*arguments, root: @root)
    output, error, status = Open3.capture3("git", "-C", root, *arguments)
    assert status.success?, "git #{arguments.join(' ')} failed: #{output}#{error}"
  end

  def test_repository_snapshot_reads_all_pages_with_full_raw_contents_and_hashes
    205.times { |index| write("lib/file_#{index}.rb", "# source #{index}\n") }
    long_text = "ż" * 20_000 + "\n"
    write("long.rb", long_text)
    write("empty.txt", "")
    write("AGENTS.md", "Use the local project conventions.\n")

    context = snapshot
    files = context.fetch("files").map { |file| [file.fetch("path"), file] }.to_h
    assert_equal 208, files.length
    assert_equal long_text, files.fetch("long.rb").fetch("content")
    assert_equal Digest::SHA256.hexdigest(long_text), files.fetch("long.rb").fetch("sha256")
    assert_equal "", files.fetch("empty.txt").fetch("content")
    assert_equal [], context.fetch("skipped_files")
  end

  def test_context_excludes_dependencies_symlinks_env_files_and_custom_globs
    write("app.rb", "puts 'app'\n")
    %w[node_modules/dependency.js vendor/bundle.rb .bundle/config .venv/lib.py .git/config .env config/.env.local docs/design.md Gemfile.lock].each do |path|
      write(path, "excluded\n")
    end
    File.symlink("app.rb", File.join(@root, "linked.rb"))
    File.symlink(Dir.tmpdir, File.join(@root, "linked-directory"))

    context = snapshot(excludes: ["docs/**", "*.lock"])
    assert_equal ["app.rb"], context.fetch("files").map { |file| file.fetch("path") }
    assert_equal [], context.fetch("skipped_files")
    assert context.fetch("symlinks_excluded")
  end

  def test_git_context_includes_tracked_and_untracked_files_and_honors_ignore_rules
    git("init", "--quiet")
    write(".gitignore", "ignored/\n*.log\n")
    write("ignored/private.txt", "do not include")
    write("debug.log", "do not include")
    write("tracked.log", "tracked even though its pattern is ignored")
    write("untracked.rb", "puts 'new'\n")
    unusual = "-quotes '\"\nfile.rb"
    write(unusual, "# odd path\n")
    git("add", "--force", "tracked.log")

    context = snapshot
    assert context.fetch("gitignore_applied")
    assert_equal [".gitignore", unusual, "tracked.log", "untracked.rb"].sort,
                 context.fetch("files").map { |file| file.fetch("path") }.sort
  end

  def test_context_in_a_repository_subdirectory_stays_within_that_workspace
    git("init", "--quiet")
    write(".gitignore", "*.log\n")
    write("outside.rb", "# outside\n")
    write("nested/app.rb", "# inside\n")
    write("nested/debug.log", "ignored\n")

    context = CodingAgent::RepositoryContext.new(File.join(@root, "nested")).build
    assert_equal ["app.rb"], context.fetch("files").map { |file| file.fetch("path") }
    assert context.fetch("gitignore_applied")
  end

  def test_context_reports_unsupported_files_and_rejects_an_incomplete_scan
    write("ok.rb", "# ok\n")
    write("binary.bin", "\0binary")
    write("invalid.txt", "\xff".b)
    write("large.txt", "x" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1))
    context = snapshot
    assert_equal ["ok.rb"], context.fetch("files").map { |file| file.fetch("path") }
    assert_equal %w[binary.bin invalid.txt large.txt], context.fetch("skipped_files").map { |file| file.fetch("path") }
    assert context.fetch("skipped_files").all? { |file| !file.fetch("reason").empty? }

    partial = Object.new
    partial.define_singleton_method(:find_files) { |*_arguments| { "scan_truncated" => true } }
    with_constructor(CodingAgent::WorkspaceTools, partial) do
      error = assert_raises(CodingAgent::Error) { snapshot }
      assert_match(/scan was incomplete/, error.message)
    end
  end

  def test_context_budget_is_exact_and_does_not_silently_truncate
    write("app.rb", "puts 'hello'\n")
    context = snapshot
    size = JSON.generate(context).bytesize
    assert_equal context, snapshot(max_bytes: size)
    error = assert_raises(CodingAgent::Error) { snapshot(max_bytes: size - 1) }
    assert_match(/no model request was sent/, error.message)
    assert_raises(CodingAgent::Error) { snapshot(max_bytes: 0) }
    assert_raises(CodingAgent::Error) { snapshot(excludes: [""]) }
  end

  def test_rewrite_preserves_permissions_and_rejects_stale_content_or_invalid_text
    write("app.rb", "puts 'before'\n")
    File.chmod(0o755, File.join(@root, "app.rb"))
    original = @workspace.read_snapshot("app.rb")
    result = @workspace.rewrite_file("app.rb", "puts 'after'\n", original.fetch("sha256"))
    assert_equal "puts 'after'\n", contents("app.rb")
    assert_equal 0o755, File.stat(File.join(@root, "app.rb")).mode & 0o777
    assert_equal Digest::SHA256.hexdigest(contents("app.rb")), result.fetch("sha256")
    assert_raises(ArgumentError) { @workspace.rewrite_file("app.rb", "stale", original.fetch("sha256")) }
    assert_raises(ArgumentError) { @workspace.rewrite_file("app.rb", "\0", result.fetch("sha256")) }
    assert_raises(ArgumentError) do
      @workspace.rewrite_file("app.rb", "x" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1), result.fetch("sha256"))
    end
    assert_equal "puts 'after'\n", contents("app.rb")
    assert_equal [], Dir.glob(File.join(@root, ".coding-agent-*.tmp"))
  end

  def test_grep_matches_regexes_case_options_single_files_and_literal_search_still_works
    skip "Regex timeouts require Ruby 3.2+" unless Regexp.respond_to?(:timeout)
    write("lib/math.rb", "def sum(a, b)\n  a + b\nend\n# SUM(1, 2)\n# sum(3, 4)\n")
    write("other.txt", "sum(5, 6)\n")
    result = @workspace.grep(".", 'sum\(', "*.rb", false, 0)
    assert_equal [1, 5], result.fetch("matches").map { |match| match.fetch("line") }
    assert result.fetch("matches").all? { |match| match.fetch("path") == "lib/math.rb" }
    insensitive = @workspace.grep("lib/math.rb", 'sum\(', "*.rb", "true", "0")
    assert_equal [1, 4, 5], insensitive.fetch("matches").map { |match| match.fetch("line") }
    assert_equal result, @workspace.grep(".", 'sum\(', "*.rb", "false", "0")
    assert_equal [2], @workspace.search_files("lib", "a + b", "*.rb", 0).fetch("matches").map { |match| match.fetch("line") }
    assert_empty @workspace.grep(".", "does_not_exist", "*", false, 0).fetch("matches")
    refute result.fetch("scan_truncated")
    assert_nil result.fetch("next_offset")
  end

  def test_grep_paginates_and_keeps_long_unicode_matching_lines_valid
    skip "Regex timeouts require Ruby 3.2+" unless Regexp.respond_to?(:timeout)
    write("matches.txt", (1..205).map { |i| "match #{i}\n" }.join)
    first = @workspace.grep(".", "^match [0-9]+$", "*.txt", false, 0)
    assert_equal 200, first.fetch("matches").length
    assert_equal 200, first.fetch("next_offset")
    assert first.fetch("truncated")
    refute first.fetch("scan_truncated")
    last = @workspace.grep(".", "^match [0-9]+$", "*.txt", false, first.fetch("next_offset"))
    assert_equal [201, 202, 203, 204, 205], last.fetch("matches").map { |match| match.fetch("line") }
    assert_nil last.fetch("next_offset")

    write("long.txt", "ż" * 20_000 + "TOKEN42" + "ż" * 1000 + "\n")
    match = @workspace.grep("long.txt", "TOKEN[0-9]+", "*", false, 0).fetch("matches").first
    assert match.fetch("text").valid_encoding?
    assert match.fetch("text_truncated")
    assert_includes match.fetch("text"), "TOKEN42"
    assert_operator match.fetch("text").bytesize, :<=, 1000
  end

  def test_grep_rejects_invalid_options_and_times_out_pathological_patterns
    skip "Regex timeouts require Ruby 3.2+" unless Regexp.respond_to?(:timeout)
    ["", "[", "x\ny", "\0", "x" * 1025].each do |pattern|
      assert_raises(ArgumentError) { @workspace.grep(".", pattern, "*", false, 0) }
    end
    assert_raises(ArgumentError) { @workspace.grep(".", "x", "*", "yes", 0) }
    assert_raises(ArgumentError) { @workspace.grep(".", "x", "", false, 0) }
    assert_raises(ArgumentError) { @workspace.grep(".", "x", "*", false, -1) }

    write("slow.txt", "a" * 10_000 + "!")
    error = assert_raises(ArgumentError) { @workspace.grep(".", '\A(a+)+\1\z', "*.txt", false, 0) }
    assert_match(/timed out/, error.message)
  end

  def test_symbols_parse_scopes_methods_and_constants_without_executing_source
    source = <<~'RUBY'
      module Example
        class Calculator
          VALUE = 1
          LEFT, RIGHT = 2, 3
          def sum(a, b)
            a + b
          end
          def self.build; new; end
          class << self
            def cached; @cached; end
            def self.meta; end
          end
        end
      end
      class Example::Calculator
        def ready?; true; end
        def []=(key, value); end
      end
      # class Fake; def fake; end; end
      text = "class Fake; def fake; end; end"
      File.write("must_not_execute.txt", "unsafe")
    RUBY
    write("lib/calculator.rb", source)
    result = @workspace.symbols(".", "", "*.rb", 0)
    expected = [
      ["Example", "module", 1], ["Example::Calculator", "class", 2],
      ["Example::Calculator::VALUE", "constant", 3],
      ["Example::Calculator::LEFT", "constant", 4], ["Example::Calculator::RIGHT", "constant", 4],
      ["Example::Calculator#sum", "method", 5], ["Example::Calculator.build", "singleton_method", 8],
      ["Example::Calculator.cached", "singleton_method", 10],
      ["Example::Calculator.singleton_class.meta", "singleton_method", 11],
      ["Example::Calculator", "class", 15], ["Example::Calculator#ready?", "method", 16],
      ["Example::Calculator#[]=", "method", 17]
    ]
    assert_equal expected, result.fetch("symbols").map { |symbol| symbol.values_at("qualified_name", "kind", "line") }
    assert result.fetch("symbols").all? { |symbol| symbol.fetch("path") == "lib/calculator.rb" }
    refute File.exist?(File.join(@root, "must_not_execute.txt"))
    refute File.exist?("must_not_execute.txt")
    assert_equal 0, result.fetch("parse_errors")
    filtered = @workspace.symbols("lib/calculator.rb", "Calculator#sum", "*", 0)
    assert_equal ["sum"], filtered.fetch("symbols").map { |symbol| symbol.fetch("name") }
    assert_empty @workspace.symbols("lib", "FAKE", "*.rb", 0).fetch("symbols")
  end

  def test_symbols_handle_absolute_constants_and_report_unresolved_receivers
    write("scope.rb", <<~'RUBY')
      module Outer
        class ::Root
          Other::VALUE ||= 1
          ::ROOT_VALUE = 2
          def self.make; end
        end
      end
      def target.custom; end
      class << target
        def custom; end
      end
      def top_level; end
    RUBY
    result = @workspace.symbols("scope.rb", "", "*", 0)
    assert_equal ["Outer", "Root", "Root::Other::VALUE", "ROOT_VALUE", "Root.make",
                  "<receiver>.custom", "<receiver>.custom", "Object#top_level"],
                 result.fetch("symbols").map { |symbol| symbol.fetch("qualified_name") }
  end

  def test_symbols_report_parse_failures_unsupported_files_and_support_ruby_build_files
    write("broken.rb", "class Broken\n")
    write("fake.py", "class NotRuby:\n    pass\n")
    %w[Gemfile Rakefile project.gemspec task.rake config.ru empty.rb].each do |path|
      write(path, path == "empty.rb" ? "" : "BUILD_VALUE = 1\n")
    end
    result = @workspace.symbols(".", "", "*", 0)
    assert_equal %w[Gemfile Rakefile config.ru project.gemspec task.rake], result.fetch("symbols").map { |symbol| symbol.fetch("path") }
    assert_equal 1, result.fetch("parse_errors")
    assert_equal 1, result.fetch("unsupported_files")
    assert_equal 2, result.fetch("skipped_files")
    assert_raises(ArgumentError) { @workspace.symbols(".", "x\ny", "*", 0) }
    assert_raises(ArgumentError) { @workspace.symbols(".", "x" * 1025, "*", 0) }
    assert_raises(ArgumentError) { @workspace.symbols(".", "", "*", -1) }
  end

  def test_symbols_paginate_within_the_result_byte_budget
    namespace = "Namespace" * 30
    methods = (1..205).map { |index| "def method_#{index}; end\n" }.join
    write("large.rb", "module #{namespace}\n#{methods}end\n")
    found = []
    offset = 0
    loop do
      page = @workspace.symbols(".", "#method_", "*.rb", offset)
      entries = page.fetch("symbols")
      refute_empty entries
      assert_operator JSON.generate(entries).bytesize, :<=, CodingAgent::WorkspaceTools::MAX_OUTPUT_BYTES
      found.concat(entries.map { |symbol| symbol.fetch("name") })
      break unless page.fetch("next_offset")

      assert_operator page.fetch("next_offset"), :>, offset
      offset = page.fetch("next_offset")
    end
    assert_equal (1..205).map { |index| "method_#{index}" }, found
  end

  def test_search_tools_reject_path_escapes_and_skip_unsupported_text_and_dependencies
    skip "Regex timeouts require Ruby 3.2+" unless Regexp.respond_to?(:timeout)
    write("ok.rb", "class Good; end\n")
    write("binary.rb", "\0")
    write("large.rb", "a" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1))
    %w[.git/secret.rb vendor/dependency.rb node_modules/module.rb].each { |path| write(path, "class Hidden; end\n") }
    File.symlink("ok.rb", File.join(@root, "linked.rb"))
    File.symlink(Dir.tmpdir, File.join(@root, "linked-dir"))
    requests = [lambda { |path| @workspace.grep(path, "class", "*.rb", false, 0) },
                lambda { |path| @workspace.symbols(path, "", "*.rb", 0) }]
    requests.each do |request|
      %w[../outside .git linked.rb linked-dir].each do |path|
        assert_raises(ArgumentError) { request.call(path) }
      end
      result = request.call(".")
      assert_equal 2, result.fetch("skipped_files")
      assert_equal ["ok.rb"], result.fetch("matches", result["symbols"]).map { |entry| entry.fetch("path") }
      refute result.fetch("scan_truncated")
    end
  end

  def test_agent_uses_grep_and_symbols_through_code_mode_without_shell_access
    skip "Regex timeouts require Ruby 3.2+" unless Regexp.respond_to?(:timeout)
    write("lib/math.rb", "def sum(a, b); a + b; end\n")
    program = <<~'RUBY'
      definitions = codemode.call_tool("workspace.symbols", path: ".", query: "", glob: "*.rb", offset: 0)
      references = codemode.call_tool("workspace.grep", path: ".", pattern: "sum\(", glob: "*.rb", ignore_case: false, offset: 0)
      {definitions: definitions, references: references}
    RUBY
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "```ruby\n#{program}```" },
      { "role" => "assistant", "content" => "FINAL: Located sum and its references." }
    )
    @client = CodingAgent.create_client(workspace: @root)
    refute_includes @client.list_tools.map(&:name), "workspace.run_command"
    CodingAgent::Agent.new(client: @client, openrouter: router, require_changes: false, output: @output, log: @log).run("Locate sum")
    execution = JSON.parse(router.requests.last.fetch(:messages).last.fetch("content").split("\n", 2).last)
    refute execution.key?("error"), execution.inspect
    results = execution.fetch("result")
    assert_equal ["Object#sum"], results.fetch("definitions").fetch("symbols").map { |symbol| symbol.fetch("qualified_name") }
    assert_equal [1], results.fetch("references").fetch("matches").map { |match| match.fetch("line") }
    %w[grep symbols].each do |name|
      assert_includes @log.string, "workspace.#{name}"
      assert_includes router.requests.first.fetch(:messages).first.fetch("content"), "workspace.#{name}"
    end
    assert_equal "def sum(a, b); a + b; end\n", contents("lib/math.rb")
  end

  def test_moves_and_deletions_require_current_hashes_and_never_overwrite_a_destination
    write("old.rb", "# original\n")
    write("occupied.rb", "# keep\n")
    File.chmod(0o755, File.join(@root, "old.rb"))
    hash = @workspace.read_snapshot("old.rb").fetch("sha256")
    assert_raises(ArgumentError) { @workspace.move_file("old.rb", "occupied.rb", hash) }
    assert_raises(ArgumentError) { @workspace.move_file("old.rb", "new.rb", "stale") }
    assert_equal "# keep\n", contents("occupied.rb")
    result = @workspace.move_file("old.rb", "lib/new.rb", hash)
    refute File.exist?(File.join(@root, "old.rb"))
    assert_equal "# original\n", contents("lib/new.rb")
    assert_equal hash, result.fetch("sha256")
    assert_equal 0o755, File.stat(File.join(@root, "lib/new.rb")).mode & 0o777

    write("lib/new.rb", "# edited by user\n")
    assert_raises(ArgumentError) { @workspace.delete_file("lib/new.rb", hash) }
    assert_equal "# edited by user\n", contents("lib/new.rb")
    current = @workspace.read_snapshot("lib/new.rb").fetch("sha256")
    assert @workspace.delete_file("lib/new.rb", current).fetch("deleted")
    refute File.exist?(File.join(@root, "lib/new.rb"))
    assert_raises(ArgumentError) { @workspace.delete_file("lib", current) }
  end

  def test_new_tools_enforce_workspace_and_symlink_boundaries
    write("app.rb", "# original\n")
    hash = @workspace.read_snapshot("app.rb").fetch("sha256")
    File.symlink("app.rb", File.join(@root, "linked.rb"))
    File.symlink(Dir.tmpdir, File.join(@root, "linked-dir"))
    ["../outside.rb", ".git/config", "linked.rb", "linked-dir/app.rb"].each do |path|
      assert_raises(ArgumentError) { @workspace.read_snapshot(path) }
      assert_raises(ArgumentError) { @workspace.rewrite_file(path, "bad", hash) }
      assert_raises(ArgumentError) { @workspace.delete_file(path, hash) }
      assert_raises(ArgumentError) { @workspace.move_file("app.rb", path, hash) }
    end
    assert_equal "# original\n", contents("app.rb")
  end

  def test_batch_edits_rollback_and_long_rewrites_commit_only_after_hash_validation
    write("README.md", "# Old\nOriginal text\n")
    hash = @workspace.read_snapshot("README.md").fetch("sha256")
    assert_raises(ArgumentError) do
      @workspace.edit_file_batch("README.md", hash, [
        { "old_text" => "Old", "new_text" => "New" },
        { "old_text" => "missing", "new_text" => "replacement" }
      ])
    end
    assert_equal "# Old\nOriginal text\n", contents("README.md")

    draft = @workspace.write_file("README.draft.md", "# New\n")
    @workspace.append_file("README.draft.md", "Rewritten text\n", draft.fetch("total_bytes"))
    assert_raises(ArgumentError) do
      @workspace.append_file("README.draft.md", "Rewritten text\n", draft.fetch("total_bytes"))
    end
    assert_raises(ArgumentError) { @workspace.commit_file("README.md", "README.draft.md", "stale") }
    assert_equal "# Old\nOriginal text\n", contents("README.md")
    @workspace.commit_file("README.md", "README.draft.md", hash)
    assert_equal "# New\nRewritten text\n", contents("README.md")
    refute File.exist?(File.join(@root, "README.draft.md"))
  end

  def test_empty_files_can_be_read_rewritten_and_used_as_drafts
    @workspace.write_file("empty.txt", "")
    page = @workspace.read_file("empty.txt", 1, 200)
    assert_equal "", page.fetch("content")
    assert_equal 0, page.fetch("returned_lines")
    assert_nil page.fetch("next_line")
    assert_equal Digest::SHA256.hexdigest(""), page.fetch("sha256")
    @workspace.append_file("empty.txt", "first chunk", 0)
    assert_equal "first chunk", contents("empty.txt")
    hash = @workspace.read_snapshot("empty.txt").fetch("sha256")
    @workspace.rewrite_file("empty.txt", "", hash)
    assert_equal "", contents("empty.txt")
  end

  def test_agent_refactors_multiple_files_through_real_code_mode_and_cli_tools
    write("lib/math.rb", "def add(a, b)\n  a + b\nend\n")
    write("app.rb", "require_relative 'lib/math'\nputs add(2, 3)\n")
    write("obsolete.txt", "remove this file\n")
    context = snapshot
    hashes = context.fetch("files").map { |file| [file.fetch("path"), file.fetch("sha256")] }.to_h
    program = <<~RUBY
      moved = codemode.call_tool("workspace.move_file", path: "lib/math.rb", destination_path: "lib/sum.rb", expected_sha256: "#{hashes.fetch('lib/math.rb')}")
      if moved["error"]
        moved
      else
        content = <<~'SOURCE'
          def sum(a, b)
            a + b
          end
        SOURCE
        rewritten = codemode.call_tool("workspace.rewrite_file", path: "lib/sum.rb", content: content, expected_sha256: moved["sha256"])
        if rewritten["error"]
          rewritten
        else
          edited = codemode.call_tool("workspace.edit_file_batch", path: "app.rb", expected_sha256: "#{hashes.fetch('app.rb')}", edits: [
            {old_text: "lib/math", new_text: "lib/sum"}, {old_text: "add(2, 3)", new_text: "sum(2, 3)"}
          ])
          removed = codemode.call_tool("workspace.delete_file", path: "obsolete.txt", expected_sha256: "#{hashes.fetch('obsolete.txt')}")
          {rewritten: rewritten, edited: edited, removed: removed}
        end
      end
    RUBY
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "```ruby\n#{program}```" },
      { "role" => "assistant", "content" => "FINAL: Renamed add to sum and updated its caller." }
    )
    @client = CodingAgent.create_client(workspace: @root)
    refute_includes @client.list_tools.map(&:name), "workspace.run_command"
    CodingAgent::Agent.new(client: @client, openrouter: router, require_changes: true, output: @output, log: @log)
                      .run("Rename add to sum, move the implementation and remove obsolete.txt", repository_context: context)

    assert_equal 2, router.requests.length
    first_messages = router.requests.first.fetch(:messages)
    assert_equal context, JSON.parse(first_messages[1].fetch("content").split("\n", 2).last)
    assert_match(/Rename add to sum/, first_messages.last.fetch("content"))
    assert_nil router.requests.first.fetch(:tools)
    execution = JSON.parse(router.requests.last.fetch(:messages).last.fetch("content").split("\n", 2).last)
    refute execution.key?("error"), execution.inspect
    execution.fetch("result").each_value { |result| refute result.key?("error"), result.inspect }
    refute File.exist?(File.join(@root, "lib/math.rb"))
    refute File.exist?(File.join(@root, "obsolete.txt"))
    assert_equal "require_relative 'lib/sum'\nputs sum(2, 3)\n", contents("app.rb")
    actual, status = Open3.capture2(RbConfig.ruby, "app.rb", chdir: @root)
    assert status.success?
    assert_equal "5\n", actual
    %w[move_file rewrite_file edit_file_batch delete_file].each { |name| assert_includes @log.string, "workspace.#{name}" }
    assert_includes @output.string, "Renamed add to sum"
    assert_includes @log.string, "Workspace file changes"
    assert_includes @log.string, '"status": "modified"'
    assert_includes @log.string, '"status": "created"'
    assert_includes @log.string, '"status": "deleted"'
  end

  def test_required_changes_reject_a_model_claim_without_edits_after_one_retry
    write("already_changed.rb", "# preexisting user changes\n")
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "FINAL: I fixed all bugs." },
      { "role" => "assistant", "content" => "FINAL: No verified bugs to fix." }
    )
    with_constructor(CodingAgent::OpenRouter, router) do
      status = CodingAgent.run_cli(["--workspace", @root, "--max-turns", "8", "Fix verified bugs"],
                                   env: {}, output: @output, log: @log)
      assert_equal 1, status
    end
    assert_equal 2, router.requests.length
    assert_includes router.requests.last.fetch(:messages).last.fetch("content"), "editing work is incomplete"
    assert_includes @log.string, "No file changes observed (--require-changes)"
    assert_includes @log.string, "No verified bugs to fix"
    refute_includes @output.string, "I fixed all bugs"
    assert_equal "# preexisting user changes\n", contents("already_changed.rb")
    assert router.closed
  end

  def test_required_changes_retry_can_produce_a_real_fix
    write("add.rb", "def add(a, b); a - b; end\n")
    program = <<~'RUBY'
      source = codemode.call_tool("workspace.read_file", path: "add.rb", start_line: 1, max_lines: 200)
      codemode.call_tool("workspace.edit_file", path: "add.rb", old_text: "a - b", new_text: "a + b")
    RUBY
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "FINAL: All done." },
      { "role" => "assistant", "content" => "```ruby\n#{program}\n```" },
      { "role" => "assistant", "content" => "FINAL: Fixed addition." }
    )
    @client = CodingAgent.create_client(workspace: @root)
    CodingAgent::Agent.new(client: @client, openrouter: router, output: @output, log: @log).run("Addition should work")
    assert_equal "def add(a, b); a + b; end\n", contents("add.rb")
    assert_equal 3, router.requests.length
    refute_includes @output.string, "All done"
    assert_includes @output.string, "Fixed addition"
    assert_includes @log.string, '"path": "add.rb"'
  end

  def test_required_changes_reject_no_op_rewrites_and_obey_the_turn_limit
    write("add.rb", "unchanged")
    hash = @workspace.read_snapshot("add.rb").fetch("sha256")
    program = <<~RUBY
      source = codemode.call_tool("workspace.read_file", path: "add.rb", start_line: 1, max_lines: 200)
      codemode.call_tool("workspace.rewrite_file", path: "add.rb", content: "unchanged", expected_sha256: "#{hash}")
    RUBY
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "```ruby\n#{program}\n```" },
      { "role" => "assistant", "content" => "FINAL: Rewritten." }
    )
    @client = CodingAgent.create_client(workspace: @root)
    agent = CodingAgent::Agent.new(client: @client, openrouter: router, max_turns: 2, require_changes: true, output: @output, log: @log)
    error = assert_raises(CodingAgent::Error) { agent.run("Fix verified bugs") }
    assert_includes error.message, "No file changes observed"
    assert_equal 2, router.requests.length
    assert_equal "unchanged", contents("add.rb")
  end

  def test_plain_prompts_read_current_source_and_rewrite_it_by_default_in_both_reply_modes
    %i[code tools].each do |mode|
      write("value.rb", "# initial version\ndef value; 1; end\n")
      current_source = "# Keep the user's latest comment\ndef value; 2; end\n"
      router = ScriptedRouter.new do |messages, _tools|
        case router.requests.length
        when 1
          # Simulate a user edit after startup but before the agent reads.
          write("value.rb", current_source)
          code = 'codemode.call_tool("workspace.read_file", path: "value.rb", start_line: 1, max_lines: 200)'
        when 2
          raw = messages.last.fetch("content")
          execution = JSON.parse(mode == :code ? raw.split("\n", 2).last : raw)
          page = execution.fetch("result")
          source = page.fetch("content").lines.map { |line| line.sub(/\A\d+: /, "") }.join
          assert_equal current_source, source
          updated = source.sub("def value; 2; end", "def value\n  2\nend")
          code = <<~RUBY
            content = <<~'SOURCE'
            #{updated}SOURCE
            codemode.call_tool("workspace.rewrite_file", path: "value.rb", content: content, expected_sha256: "#{page.fetch('sha256')}")
          RUBY
        else
          next({ "role" => "assistant", "content" => mode == :code ? "FINAL: Simplified value.rb." : "Simplified value.rb." })
        end
        if mode == :code
          { "role" => "assistant", "content" => "```ruby\n#{code}\n```" }
        else
          { "role" => "assistant", "tool_calls" => [{ "id" => "call_#{router.requests.length}", "type" => "function",
            "function" => { "name" => "execute_code", "arguments" => JSON.generate("code" => code) } }] }
        end
      end
      with_constructor(CodingAgent::OpenRouter, router) do
        status = CodingAgent.run_cli(["--workspace", @root, "--response-mode", mode.to_s, "Make this clearer"],
                                     env: {}, output: @output, log: @log)
        assert_equal 0, status, @log.string
      end
      assert_equal "# Keep the user's latest comment\ndef value\n  2\nend\n", contents("value.rb")
      assert_equal 3, router.requests.length
    end
  end

  def test_agent_rejects_unread_files_and_requires_all_pages_for_a_full_rewrite
    write("source.rb", "first\nsecond\nthird\n")
    client = guarded_client
    hash = @workspace.read_snapshot("source.rb").fetch("sha256")
    rewrite = lambda { client.call_tool("workspace.rewrite_file", path: "source.rb", content: "updated\n", expected_sha256: hash) }
    client.call_tool("workspace.search_files", path: ".", query: "first", glob: "*.rb", offset: 0)
    error = assert_raises(ArgumentError, &rewrite)
    assert_match(/Read .* before modifying/, error.message)

    client.call_tool("workspace.read_files", files: [{ path: "missing.rb" }, { path: "source.rb", max_lines: 1 }])
    assert_match(/Read all pages/, assert_raises(ArgumentError, &rewrite).message)
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 3, max_lines: 1)
    assert_raises(ArgumentError, &rewrite)
    assert_equal "first\nsecond\nthird\n", contents("source.rb")
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 2, max_lines: 1)
    refute rewrite.call.key?("error")
    assert_equal "updated\n", contents("source.rb")
    assert_nil client.execution_trace.completion_problem
  end

  def test_agent_rejects_stale_reads_for_exact_edits_and_preserves_current_user_changes
    write("source.rb", "header\nkeep\n")
    File.chmod(0o755, File.join(@root, "source.rb"))
    client = guarded_client
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 1, max_lines: 200)
    write("source.rb", "HEADER\nkeep\n")
    edit = lambda { client.call_tool("workspace.edit_file", path: "source.rb", old_text: "keep", new_text: "kept") }
    error = assert_raises(ArgumentError, &edit)
    assert_match(/File changed since it was read/, error.message)
    assert_equal "HEADER\nkeep\n", contents("source.rb")
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 1, max_lines: 200)
    refute edit.call.key?("error")
    assert_equal "HEADER\nkept\n", contents("source.rb")
    assert_equal 0o755, File.stat(File.join(@root, "source.rb")).mode & 0o777
    assert_nil client.execution_trace.completion_problem
  end

  def test_old_snapshot_and_pages_from_different_versions_cannot_authorize_a_rewrite
    write("source.rb", "one\ntwo\n")
    context = snapshot
    client = guarded_client
    client.execution_trace.seed_context(context)
    write("source.rb", "ONE\ntwo\n")
    stale_hash = context.fetch("files").first.fetch("sha256")
    error = assert_raises(ArgumentError) do
      client.call_tool("workspace.rewrite_file", path: "source.rb", content: "lost\n", expected_sha256: stale_hash)
    end
    assert_match(/File changed since it was read/, error.message)
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 1, max_lines: 1)
    write("source.rb", "new\ntwo\n")
    page = client.call_tool("workspace.read_file", path: "source.rb", start_line: 2, max_lines: 1)
    error = assert_raises(ArgumentError) do
      client.call_tool("workspace.rewrite_file", path: "source.rb", content: "lost\n", expected_sha256: page.fetch("sha256"))
    end
    assert_match(/Read all pages/, error.message)
    assert_equal "new\ntwo\n", contents("source.rb")
  end

  def test_empty_pages_do_not_count_as_reading_a_nonempty_file_and_runs_reset_read_state
    write("source.rb", "current\n")
    client = guarded_client
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 1000, max_lines: 200)
    edit = lambda { client.call_tool("workspace.edit_file", path: "source.rb", old_text: "current", new_text: "updated") }
    assert_raises(ArgumentError, &edit)
    client.call_tool("workspace.read_file", path: "source.rb", start_line: 1, max_lines: 200)
    client.execution_trace.reset
    assert_raises(ArgumentError, &edit)
    assert_equal "current\n", contents("source.rb")
  end

  def test_draft_rewrites_use_known_new_content_and_reject_same_size_external_changes
    write("README.md", "old\n")
    client = guarded_client
    original = client.call_tool("workspace.read_file", path: "README.md", start_line: 1, max_lines: 200)
    client.call_tool("workspace.write_file", path: "draft.md", content: "new\n")
    write("draft.md", "bad\n")
    assert_raises(ArgumentError) { client.call_tool("workspace.append_file", path: "draft.md", content: "more\n", expected_bytes: 4) }
    assert_equal "bad\n", contents("draft.md")
    draft = client.call_tool("workspace.read_file", path: "draft.md", start_line: 1, max_lines: 200)
    client.call_tool("workspace.rewrite_file", path: "draft.md", content: "new\n", expected_sha256: draft.fetch("sha256"))
    client.call_tool("workspace.append_file", path: "draft.md", content: "more\n", expected_bytes: 4)
    client.call_tool("workspace.commit_file", path: "README.md", draft_path: "draft.md", expected_sha256: original.fetch("sha256"))
    assert_equal "new\nmore\n", contents("README.md")
    refute File.exist?(File.join(@root, "draft.md"))
    assert_nil client.execution_trace.completion_problem
  end

  def test_blind_shell_changes_and_later_no_op_edits_do_not_satisfy_the_read_then_edit_workflow
    write("target.txt", "before")
    write("unrelated.txt", "read only")
    client = guarded_client(allow_shell: true)
    client.call_tool("workspace.read_file", path: "unrelated.txt", start_line: 1, max_lines: 200)
    client.call_tool("workspace.run_command", command: "printf after > target.txt")
    assert_match(/No change based on a current file read/, client.execution_trace.completion_problem)
    client.call_tool("workspace.read_file", path: "target.txt", start_line: 1, max_lines: 200)
    client.call_tool("workspace.edit_file", path: "target.txt", old_text: "after", new_text: "after")
    assert_match(/No change based on a current file read/, client.execution_trace.completion_problem)
    assert_equal "after", contents("target.txt")
  end

  def test_new_file_tasks_require_readback_before_default_completion
    client = guarded_client
    client.call_tool("workspace.write_file", path: "new.rb", content: "puts 'new'\n")
    assert_match(/No file contents were read/, client.execution_trace.completion_problem)
    client.call_tool("workspace.read_file", path: "new.rb", start_line: 1, max_lines: 200)
    assert_nil client.execution_trace.completion_problem
    assert_equal "puts 'new'\n", contents("new.rb")
  end

  def test_change_tracking_handles_reverts_drafts_path_aliases_and_partial_errors
    write("original.txt", "before")
    trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    trace.step("workspace.edit_file", { path: "./original.txt" }) { @workspace.edit_file("original.txt", "before", "after") }
    assert_equal [{ "path" => "original.txt", "status" => "modified" }], trace.file_changes
    trace.step("workspace.edit_file", { "path" => "original.txt" }) { @workspace.edit_file("original.txt", "after", "before") }
    assert_empty trace.file_changes
    trace.step("workspace.write_file", { path: "draft.txt" }) { @workspace.write_file("draft.txt", "replacement") }
    hash = @workspace.read_snapshot("original.txt").fetch("sha256")
    trace.step("workspace.commit_file", { path: "original.txt", draft_path: "draft.txt" }) do
      @workspace.commit_file("original.txt", "draft.txt", hash)
    end
    assert_equal [{ "path" => "original.txt", "status" => "modified" }], trace.file_changes
    assert_raises(RuntimeError) do
      trace.step("workspace.write_file", { path: "partial.txt" }) do
        @workspace.write_file("partial.txt", "created before error")
        raise "failure after writing"
      end
    end
    assert_equal %w[original.txt partial.txt], trace.file_changes.map { |change| change.fetch("path") }
    trace.reset
    assert_empty trace.file_changes
  end

  def test_change_tracking_does_not_count_failed_or_unsupported_operations
    write("unchanged.txt", "before")
    File.symlink("unchanged.txt", File.join(@root, "link.txt"))
    trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    %w[unchanged.txt link.txt .git/config ../outside.txt].each do |path|
      trace.step("workspace.edit_file", { path: path }) { { "error" => "edit failed" } }
    end
    assert_empty trace.file_changes
  end

  def test_required_changes_also_reject_native_final_replies
    router = ScriptedRouter.new({ "role" => "assistant", "content" => "Everything is fine." })
    @client = CodingAgent.create_client(workspace: @root)
    agent = CodingAgent::Agent.new(client: @client, openrouter: router, response_mode: :tools,
                                  require_changes: true, max_turns: 1, output: @output, log: @log)
    assert_raises(CodingAgent::Error) { agent.run("Fix verified bugs") }
    assert_equal 1, router.requests.length
    assert_empty @output.string
  end

  def test_required_changes_accept_actual_shell_edits
    write("add.rb", "def add(a, b); a - b; end\n")
    program = <<~'RUBY'
      source = codemode.call_tool("workspace.read_file", path: "add.rb", start_line: 1, max_lines: 200)
      command = <<~'SH'
        printf '%s\n' 'def add(a, b); a + b; end' > add.rb
      SH
      codemode.call_tool("workspace.run_command", command: command)
    RUBY
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => "```ruby\n#{program}```" },
      { "role" => "assistant", "content" => "FINAL: Fixed addition." }
    )
    @client = CodingAgent.create_client(workspace: @root, allow_shell: true)
    CodingAgent::Agent.new(client: @client, openrouter: router, require_changes: true, output: @output, log: @log).run("Fix addition")
    assert_equal "def add(a, b); a + b; end\n", contents("add.rb")
    assert_equal 2, router.requests.length
    assert_includes @log.string, '"path": "add.rb"'
    assert_includes @log.string, '"status": "modified"'
    refute_includes @log.string, "No file-content changes"
    assert_includes @output.string, "Fixed addition"
  end

  def test_shell_tracking_uses_current_files_as_baseline_and_reports_creations_and_deletions
    write("user_changes.txt", "already modified before the run")
    write("remove.txt", "remove")
    trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    trace.step("workspace.run_command", { command: "true" }) { @workspace.run_command("true") }
    assert_empty trace.file_changes
    trace.step("workspace.run_command", { command: "modify files" }) do
      @workspace.run_command("printf created > new.txt; rm remove.txt; exit 7")
    end
    assert_equal [
      { "path" => "new.txt", "status" => "created" },
      { "path" => "remove.txt", "status" => "deleted" }
    ], trace.file_changes
    assert_equal "already modified before the run", contents("user_changes.txt")
  end

  def test_mixed_file_and_shell_edits_are_compared_with_the_original_contents
    write("original.txt", "before")
    trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    trace.step("workspace.edit_file", { path: "original.txt" }) { @workspace.edit_file("original.txt", "before", "after") }
    trace.step("workspace.run_command", { command: "revert original and create new file" }) do
      @workspace.run_command("printf before > original.txt; printf new > created.txt")
    end
    trace.step("workspace.edit_file", { path: "created.txt" }) { @workspace.edit_file("created.txt", "new", "updated") }
    assert_equal [{ "path" => "created.txt", "status" => "created" }], trace.file_changes
    trace.step("workspace.delete_file", { path: "created.txt" }) do
      @workspace.delete_file("created.txt", @workspace.read_snapshot("created.txt").fetch("sha256"))
    end
    assert_empty trace.file_changes
  end

  def test_shell_snapshot_does_not_misclassify_excluded_existing_files_as_created
    write("node_modules/existing.txt", "before")
    trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    trace.step("workspace.run_command", { command: "true" }) { @workspace.run_command("true") }
    trace.step("workspace.edit_file", { path: "node_modules/existing.txt" }) do
      @workspace.edit_file("node_modules/existing.txt", "before", "before")
    end
    assert_empty trace.file_changes
    trace.report_file_changes
    assert_includes @log.string, "Change tracking limits"
  end

  def test_workspace_fingerprints_handle_binary_empty_and_oversized_files
    write("binary.bin", "\0\xff".b)
    write("empty.txt", "")
    write("large.bin", "x" * (CodingAgent::WorkspaceTools::MAX_FILE_BYTES + 1))
    File.symlink("binary.bin", File.join(@root, "link.bin"))
    state = @workspace.workspace_fingerprints
    files = state.fetch("files")
    assert state.fetch("complete")
    assert_equal Digest::SHA256.hexdigest("\0\xff".b), files.fetch(File.join(@root, "binary.bin"))
    assert_equal Digest::SHA256.hexdigest(""), files.fetch(File.join(@root, "empty.txt"))
    assert_equal CodingAgent::WorkspaceTools::UNKNOWN_FINGERPRINT, files.fetch(File.join(@root, "large.bin"))
    refute files.key?(File.join(@root, "link.bin"))
  end

  def test_incomplete_shell_baseline_does_not_claim_preexisting_files_are_new
    write("existing.txt", "preexisting")
    fake = Object.new
    fingerprint = Digest::SHA256.hexdigest("preexisting")
    snapshots = [
      { "files" => {}, "complete" => false },
      { "files" => { File.join(@root, "existing.txt") => fingerprint }, "complete" => true }
    ]
    fake.define_singleton_method(:workspace_fingerprints) { snapshots.length > 1 ? snapshots.shift : snapshots.first }
    trace = nil
    with_constructor(CodingAgent::WorkspaceTools, fake) do
      trace = CodingAgent::ExecutionTrace.new(@log, workspace: @root)
    end
    trace.step("workspace.run_command", {}) { { "exit_code" => 0 } }
    assert_empty trace.file_changes
    trace.report_file_changes
    assert_includes @log.string, "changes outside the verified paths are unknown"
  end

  def test_native_tool_call_replies_and_shell_opt_in
    @client = CodingAgent.create_client(workspace: @root, allow_shell: true)
    assert_includes @client.list_tools.map(&:name), "workspace.run_command"
    code = 'codemode.call_tool("workspace.run_command", command: "printf verified")'
    router = ScriptedRouter.new(
      { "role" => "assistant", "content" => nil, "tool_calls" => [{
        "id" => "call_1", "type" => "function",
        "function" => { "name" => "execute_code", "arguments" => JSON.generate("code" => code) }
      }] },
      { "role" => "assistant", "content" => "Verified the command." }
    )
    CodingAgent::Agent.new(client: @client, openrouter: router, response_mode: :tools, require_changes: false, output: @output, log: @log).run("Check shell access")
    message = router.requests.last.fetch(:messages).last
    assert_equal "tool", message.fetch("role")
    assert_equal "call_1", message.fetch("tool_call_id")
    assert_equal "verified", JSON.parse(message.fetch("content")).fetch("result").fetch("output")
    assert_equal CodingAgent::Agent::TOOLS, router.requests.first.fetch(:tools)
  end

  def test_cli_loads_context_and_closes_resources_without_network_access
    write("app.rb", "# hello\n")
    router = ScriptedRouter.new({ "role" => "assistant", "content" => "FINAL: Inspected the repository." })
    with_constructor(CodingAgent::OpenRouter, router) do
      status = CodingAgent.run_cli(["--workspace", @root, "--context", "repository", "--no-require-changes", "Inspect all files"],
                                   env: {}, output: @output, log: @log)
      assert_equal 0, status, @log.string
    end
    assert router.closed
    assert_equal 1, router.requests.length
    assert_includes router.requests.first.fetch(:messages)[1].fetch("content"), "app.rb"
    assert_includes @log.string, "Repository context: 1 files"
  end

  def test_cli_rejects_excessive_context_before_the_first_model_request
    write("app.rb", "# hello\n")
    router = ScriptedRouter.new
    with_constructor(CodingAgent::OpenRouter, router) do
      status = CodingAgent.run_cli(["--workspace", @root, "--context", "repository", "--max-context-bytes", "1", "Inspect"],
                                   env: {}, output: @output, log: @log)
      assert_equal 1, status
    end
    assert router.closed
    assert_empty router.requests
    assert_includes @log.string, "no model request was sent"
  end

  def test_cli_passes_request_limits_and_progress_output_to_the_router
    router = ScriptedRouter.new({ "role" => "assistant", "content" => "FINAL: No verified changes." })
    with_constructor(CodingAgent::OpenRouter, router) do |calls|
      status = CodingAgent.run_cli(["--workspace", @root, "--request-timeout", "45", "--max-tokens", "2048", "--no-require-changes", "Inspect"],
                                   env: {}, output: @output, log: @log)
      assert_equal 0, status, @log.string
      assert_equal 45.0, calls.first.fetch(:request_timeout)
      assert_equal 2048, calls.first.fetch(:max_tokens)
      assert_same @log, calls.first.fetch(:log)
    end
    assert router.closed
  end

  def test_help_and_invalid_options_need_no_credentials
    assert_equal 0, CodingAgent.run_cli(["--help"], env: {}, output: @output, log: @log)
    assert_includes @output.string, "--context MODE"
    assert_includes @output.string, "--exclude-context GLOB"
    assert_includes @output.string, "--request-timeout SECONDS"
    assert_includes @output.string, "--[no-]require-changes"
    assert_equal 1, CodingAgent.run_cli(["--context", "invalid", "Task"], env: {}, output: @output, log: @log)
    assert_equal 1, CodingAgent.run_cli(["--max-context-bytes", "0", "Task"], env: {}, output: @output, log: @log)
    assert_equal 1, CodingAgent.run_cli(["--request-timeout", "0", "Task"], env: {}, output: @output, log: @log)
  end
end
