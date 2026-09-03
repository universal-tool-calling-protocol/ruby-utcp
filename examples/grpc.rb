# frozen_string_literal: true

require "rbconfig"

begin
  require "grpc"
rescue LoadError => load_error
  unless ENV["UTCP_RBENV_REEXEC"] == "1"
    rbenv = [ENV["RBENV_BIN"], "/opt/homebrew/bin/rbenv", "/usr/local/bin/rbenv", "rbenv"]
      .compact.find { |candidate| candidate == "rbenv" || File.executable?(candidate) }
    begin
      selected_ruby = IO.popen([rbenv, "which", "ruby"], err: File::NULL, &:read).to_s.strip
      unless selected_ruby.empty? || File.expand_path(selected_ruby) == File.expand_path(RbConfig.ruby)
        root = File.expand_path("..", __dir__)
        exec({ "UTCP_RBENV_REEXEC" => "1" }, selected_ruby, "-I#{File.join(root, "lib")}", __FILE__, *ARGV)
      end
    rescue Errno::ENOENT
      nil
    end
  end

  warn "Unable to load grpc with #{RbConfig.ruby}: #{load_error.message}"
  warn "Install it for the active Ruby with: gem install grpc"
  exit 1
end

require "utcp"

# Add `gem "grpc"` to the application. The server implements grpcpb.UTCPService
# with GetManual, CallTool, and optionally CallToolStream.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "rpc",
    call_template_type: "grpc",
    host: ENV.fetch("UTCP_GRPC_HOST", "localhost"),
    port: Integer(ENV.fetch("UTCP_GRPC_PORT", "50051")),
    service_name: "grpcpb.UTCPService",
    use_ssl: ENV["UTCP_GRPC_TLS"] == "1"
  }]
})

puts client.call_tool("rpc.echo", message: "Hello over gRPC").inspect
