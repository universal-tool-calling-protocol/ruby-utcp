# frozen_string_literal: true

require "set"
require_relative "workspace_tools"
require_relative "openrouter"

module CodingAgent
  # Built locally before any model request. The snapshot is ordinary message
  # data, so it is independent of the Code Mode interpreter's value limits.
  class RepositoryContext
    DEFAULT_MAX_BYTES = 1024 * 1024
    DEFAULT_EXCLUDES = %w[.env .env.*].freeze

    def initialize(root, max_bytes: DEFAULT_MAX_BYTES, excludes: [])
      unless max_bytes.is_a?(Integer) && max_bytes.positive?
        raise Error, "--max-context-bytes must be positive"
      end
      unless excludes.is_a?(Array) && excludes.all? { |glob| glob.is_a?(String) && !glob.empty? }
        raise Error, "Context exclusions must be nonempty globs"
      end

      @root = File.realpath(root)
      @workspace = WorkspaceTools.new(@root)
      @max_bytes = max_bytes
      @excludes = DEFAULT_EXCLUDES + excludes
    end

    def build
      git = git_repository?
      snapshot = {
        "gitignore_applied" => git,
        "excluded_directories" => WorkspaceTools::HIDDEN_DIRECTORIES,
        "excluded_globs" => @excludes,
        "symlinks_excluded" => true,
        "files" => [], "skipped_files" => []
      }
      bytes = JSON.generate(snapshot).bytesize
      offset = 0
      loop do
        page = @workspace.find_files(".", "**/*", offset)
        if page["scan_truncated"] || page["skipped_files"].positive?
          raise Error, "Repository scan was incomplete. Select a smaller --workspace or use --context tools"
        end

        paths = page.fetch("files")
        ignored = git ? ignored_paths(paths) : Set.new
        paths.each do |path|
          next if ignored.include?(path) || excluded?(path)

          collection = "files"
          begin
            item = @workspace.read_snapshot(path)
          rescue ArgumentError, SystemCallError => error
            collection = "skipped_files"
            item = { "path" => path, "reason" => error.message }
          end
          bytes += JSON.generate(item).bytesize
          bytes += 1 unless snapshot[collection].empty?
          check_size!(bytes)
          snapshot[collection] << item
        end
        offset = page["next_offset"]
        break unless offset
      end
      check_size!(bytes)
      snapshot
    end

    private

    def check_size!(bytes)
      return if bytes <= @max_bytes

      raise Error, "Repository context exceeds #{@max_bytes} bytes; no model request was sent. " \
                   "Increase --max-context-bytes, add --exclude-context globs, select a smaller --workspace, " \
                   "or use --context tools"
    end

    def excluded?(path)
      @excludes.any? do |glob|
        candidate = glob.include?("/") ? path : File.basename(path)
        File.fnmatch?(glob, candidate, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
      end
    end

    def git_repository?
      output, error, status = git_command("rev-parse", "--is-inside-work-tree")
      return output.strip == "true" if status.success?
      return false if error.include?("not a git repository")

      raise Error, "Cannot determine repository ignore rules: #{error.strip}"
    rescue Errno::ENOENT
      # Plain directories work without Git; default and explicit globs still apply.
      false
    end

    def ignored_paths(paths)
      return Set.new if paths.empty?

      output, error, status = git_command("check-ignore", "--stdin", "-z", input: paths.join("\0") + "\0")
      unless [0, 1].include?(status.exitstatus)
        raise Error, "Cannot read repository ignore rules: #{error.strip}"
      end
      output.split("\0").to_set
    end

    def git_command(*arguments, input: "")
      # Avoid inheriting GIT_DIR/GIT_WORK_TREE or credentials. Git only queries
      # local ignore metadata; no user-authored shell command is executed here.
      environment = { "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"), "HOME" => ENV["HOME"], "LC_ALL" => "C" }
      Open3.capture3(environment, "git", "-C", @root, *arguments, stdin_data: input, unsetenv_others: true)
    end
  end
end
