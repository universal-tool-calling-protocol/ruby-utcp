# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "open3"
require "pathname"
require "tempfile"
require "timeout"

module RubyUTCPAgent
  # These are application guardrails, not an OS sandbox. Approved commands can
  # execute arbitrary programs; use a disposable checkout/container for untrusted code.
  class Workspace
    MAX_FILE_BYTES = 1024 * 1024
    MAX_OUTPUT_BYTES = 32 * 1024
    MAX_FILES = 1000
    MAX_VISITS = 10_000
    IGNORED = %w[node_modules vendor tmp coverage .bundle .venv __pycache__].freeze
    OPERATIONS = %w[list_files read_file search write_file replace_text run_command].freeze
    MUTATIONS = %w[write_file replace_text run_command].freeze

    attr_reader :root

    def initialize(root:, approve:, read_only: false)
      @root = File.realpath(root)
      raise ArgumentError, "workspace must be a directory" unless File.directory?(@root)

      @approve = approve
      @read_only = read_only
    end

    def call(name, arguments = {})
      raise ArgumentError, "unknown workspace tool: #{name}" unless OPERATIONS.include?(name)
      raise ArgumentError, "tool arguments must be an object" unless arguments.is_a?(Hash)
      return denied("read-only mode") if @read_only && MUTATIONS.include?(name)

      send(name, **arguments.each_with_object({}) { |(key, value), hash| hash[key.to_sym] = value })
    end

    private

    def list_files(path: ".")
      directory = resolve(path)
      raise ArgumentError, "not a directory" unless File.directory?(directory)

      files = []
      visits = 0
      truncated = false
      Find.find(directory) do |entry|
        visits += 1
        if visits > MAX_VISITS || files.length >= MAX_FILES
          truncated = true
          break
        end
        next if entry == directory

        base = File.basename(entry)
        if File.symlink?(entry) || blocked?(base) || (File.directory?(entry) && IGNORED.include?(base))
          Find.prune
        elsif File.file?(entry) && File.stat(entry).nlink == 1
          files << relative(entry)
        end
      end
      { "files" => files.sort, "truncated" => truncated }
    end

    def read_file(path:, start_line: 1, max_lines: 200)
      bounded_integer!(start_line, "start_line", 1, 1_000_000)
      bounded_integer!(max_lines, "max_lines", 1, 1000)
      text = read_text(resolve(path))
      lines = text.lines
      selected = (lines[(start_line - 1), max_lines] || []).join
      content = clip(selected, MAX_OUTPUT_BYTES)
      { "path" => path, "content" => content, "sha256" => sha(text),
        "start_line" => start_line, "total_lines" => lines.length,
        "truncated" => selected.bytesize > MAX_OUTPUT_BYTES || start_line - 1 + max_lines < lines.length }
    end

    def search(query:, path: ".")
      string!(query, "query", allow_empty: false)
      listing = list_files(path: path)
      matches = []
      truncated = listing["truncated"]
      listing["files"].each do |file|
        begin
          read_text(resolve(file)).each_line.with_index(1) do |line, index|
            next unless line.include?(query)

            matches << { "path" => file, "line" => index, "text" => clip(line.chomp, 512) }
            if matches.length >= 50
              truncated = true
              break
            end
          end
        rescue ArgumentError, SystemCallError
          next # Skip binary, oversized, or concurrently removed files.
        end
        break if matches.length >= 50
      end
      { "matches" => matches, "truncated" => truncated }
    end

    def write_file(path:, content:, expected_sha256: nil)
      string!(content, "content")
      raise ArgumentError, "content exceeds #{MAX_FILE_BYTES} bytes" if content.bytesize > MAX_FILE_BYTES

      target = resolve(path)
      before = current_text(target)
      check_revision!(before, expected_sha256)
      return { "path" => path, "changed" => false, "sha256" => sha(content) } if before == content

      preview = { "path" => path, "before" => before, "after" => content }
      return denied("user declined") unless @approve.call("write_file", preview)

      # Recheck after the approval prompt: a human/editor may have changed the file.
      target = resolve(path)
      check_revision!(current_text(target), expected_sha256)
      FileUtils.mkdir_p(File.dirname(target))
      target = resolve(path)
      Tempfile.create([".coding-agent-", ".tmp"], File.dirname(target)) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
        file.chmod(File.stat(target).mode & 0o777) if File.exist?(target)
        check_revision!(current_text(resolve(path)), expected_sha256)
        File.rename(file.path, target)
      end
      { "path" => path, "changed" => true, "sha256" => sha(content), "bytes" => content.bytesize }
    end

    def replace_text(path:, old_text:, new_text:, expected_sha256:)
      string!(old_text, "old_text", allow_empty: false)
      string!(new_text, "new_text")
      original = read_text(resolve(path))
      check_revision!(original, expected_sha256)
      unless original.scan(Regexp.new(Regexp.escape(old_text))).length == 1
        raise ArgumentError, "old_text must match exactly once; read the file and choose a unique block"
      end
      write_file(path: path, content: original.sub(old_text) { new_text }, expected_sha256: expected_sha256)
    end

    def run_command(argv:, timeout_seconds: 30)
      unless argv.is_a?(Array) && !argv.empty? && argv.length <= 128
        raise ArgumentError, "argv must be a non-empty array of at most 128 strings"
      end
      argv.each { |arg| string!(arg, "argv entry") }
      raise ArgumentError, "executable cannot be empty" if argv.first.empty?
      raise ArgumentError, "command arguments exceed 64 KiB" if argv.sum(&:bytesize) > 65_536

      bounded_integer!(timeout_seconds, "timeout_seconds", 1, 120)
      details = { "argv" => argv, "cwd" => root, "timeout_seconds" => timeout_seconds }
      return denied("user declined") unless @approve.call("run_command", details)

      environment = %w[PATH HOME LANG LC_ALL TMPDIR].each_with_object({}) do |key, values|
        values[key] = ENV[key] if ENV.key?(key)
      end
      output = +"".b
      truncated = false
      timed_out = false
      status = nil
      # The [executable, argv0] form explicitly disables Ruby's single-string shell shortcut.
      Open3.popen2e(environment, [argv.first, argv.first], *argv.drop(1),
                   chdir: root, unsetenv_others: true, pgroup: true) do |stdin, stdout, process|
        stdin.close
        begin
          Timeout.timeout(timeout_seconds) do
            begin
              loop do
                chunk = stdout.readpartial(8192)
                remaining = MAX_OUTPUT_BYTES - output.bytesize
                output << chunk.byteslice(0, remaining) if remaining.positive?
                truncated ||= chunk.bytesize > remaining
              end
            rescue EOFError
              status = process.value
            end
          end
        rescue Timeout::Error
          timed_out = true
        ensure
          terminate_group(process.pid)
          status ||= process.value
        end
      end
      { "output" => output.force_encoding(Encoding::UTF_8).scrub("?"),
        "exit_status" => status.exitstatus, "timed_out" => timed_out,
        "output_truncated" => truncated }
    end

    def terminate_group(pid)
      Process.kill("TERM", -pid)
      sleep(0.05)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    def resolve(path)
      string!(path, "path", allow_empty: false)
      parts = path.split(File::SEPARATOR)
      if Pathname.new(path).absolute? || parts.include?("..") || parts.any? { |part| blocked?(part) }
        raise ArgumentError, "path is outside the workspace or points to a protected file"
      end
      candidate = File.expand_path(path, root)
      unless candidate == root || candidate.start_with?(root + File::SEPARATOR)
        raise ArgumentError, "path is outside the workspace"
      end
      current = root
      parts.each do |part|
        next if part.empty? || part == "."

        current = File.join(current, part)
        raise ArgumentError, "symlinks are not permitted" if File.symlink?(current)
        if File.file?(current) && File.stat(current).nlink > 1
          raise ArgumentError, "hardlinked files are not permitted"
        end
      end
      candidate
    end

    def blocked?(name)
      %w[.git .ssh .aws .gnupg id_rsa id_ed25519].include?(name) ||
        name.start_with?(".env") || name.end_with?(".pem", ".key")
    end

    def read_text(path)
      raise ArgumentError, "not a regular file" unless File.file?(path)

      content = File.open(path, "rb") { |file| file.read(MAX_FILE_BYTES + 1) }
      raise ArgumentError, "file exceeds #{MAX_FILE_BYTES} bytes" if content.bytesize > MAX_FILE_BYTES

      content.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "file must contain UTF-8 text without NUL bytes" unless content.valid_encoding? && !content.include?("\0")

      content
    end

    def current_text(path)
      File.exist?(path) ? read_text(path) : nil
    end

    def check_revision!(before, expected)
      matches = before.nil? ? expected.nil? : expected == sha(before)
      raise ArgumentError, "file revision changed or missing; read_file and supply its sha256 as expected_sha256" unless matches
    end

    def string!(value, name, allow_empty: true)
      unless value.is_a?(String) && value.valid_encoding? && !value.include?("\0") && (allow_empty || !value.empty?)
        raise ArgumentError, "#{name} must be #{allow_empty ? 'a' : 'a non-empty'} string without NUL bytes"
      end
    end

    def bounded_integer!(value, name, minimum, maximum)
      unless value.is_a?(Integer) && value.between?(minimum, maximum)
        raise ArgumentError, "#{name} must be an integer between #{minimum} and #{maximum}"
      end
    end

    def relative(path)
      Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end

    def clip(text, bytes)
      text.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub("")
    end

    def denied(reason)
      { "status" => "denied", "reason" => reason, "changed" => false }
    end
  end
end
