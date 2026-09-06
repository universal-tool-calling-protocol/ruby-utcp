# frozen_string_literal: true

require_relative "../../lib/utcp"
require_relative "../support/soak_runner"
require "socket"
require "timeout"

module TransportSoak
  # Both ends run locally. The server generates one bounded response per request
  # and removes finished worker threads, so it cannot retain request history.
  class HTTPWorkload
    EVENTS = 128
    VALUE = { "text" => "zażółć" * 32 }.freeze

    def initialize(concurrency)
      @concurrency = concurrency
      @iteration = 0
      @mutex = Mutex.new
      @workers = []
      @errors = Queue.new
      @server = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@server.addr[1]}"
      @sse = UTCP::SSEProtocol.new
      @ndjson = UTCP::StreamableHTTPProtocol.new
      @listener = Thread.new do
        loop do
          socket = @server.accept
          @mutex.synchronize do
            worker = Thread.new(socket) do |connection|
              serve(connection)
            rescue IOError, SystemCallError => error
              @errors << error unless @closed
            rescue StandardError => error
              @errors << error
            ensure
              connection.close unless connection.closed?
              @mutex.synchronize { @workers.delete(Thread.current) }
            end
            worker.report_on_exception = false
            @workers << worker
          end
        end
      rescue IOError, Errno::EBADF
        raise unless @closed
      end
    end

    def batch
      raise @errors.pop unless @errors.empty?
      iteration = (@iteration += 1)
      counts = TransportSoak.parallel(@concurrency) do |index|
        type = (iteration + index).even? ? :sse : :ndjson
        mode = (iteration + index) % 3
        protocol = type == :sse ? @sse : @ndjson
        options = { url: "#{@url}/#{type}", max_response_bytes: 128 * 1024 }
        options[:max_response_bytes] = 1024 if mode == 2
        template = if type == :sse
                     UTCP::SseCallTemplate.new(**options, timeout: 2, total_timeout: 3)
                   else
                     UTCP::StreamableHttpCallTemplate.new(**options, timeout: 2000, total_timeout: 3)
                   end
        stream = protocol.call_tool_streaming(nil, "events", {}, template)
        received = 0
        begin
          stream.each do |value|
            raise Failure, "#{type} corrupted a response" unless value == VALUE
            received += 1
            break if mode == 1 && received == 3
          end
          raise Failure, "Response byte limit did not fire" if mode == 2
          expected = mode == 1 ? 3 : EVENTS
          raise Failure, "Expected #{expected} events, got #{received}" unless received == expected
        rescue UTCP::ToolCallError => error
          raise unless mode == 2 && error.message.include?("max_response_bytes")
        end
        { "events" => received, "requests" => 1, "early_exits" => mode == 1 ? 1 : 0,
          "limit_errors" => mode == 2 ? 1 : 0 }
      end
      # Wait for server cleanup before comparing quiescent resource samples.
      Timeout.timeout(3) do
        loop do
          workers = @mutex.synchronize { @workers.dup }
          break if workers.empty?
          workers.each(&:join)
        end
      end
      raise @errors.pop unless @errors.empty?
      counts.each_with_object(Hash.new(0)) { |values, total| values.each { |key, value| total[key] += value } }
    end

    def close
      @closed = true
      @server.close unless @server.closed?
      @listener.join(3)
      @listener.kill.join if @listener.alive?
      @mutex.synchronize { @workers.dup }.each { |worker| worker.kill.join }
    end

    private

    def serve(socket)
      request = socket.gets
      return unless request
      while (line = socket.gets) && line != "\r\n"; end
      sse = request.include?("/sse")
      content_type = sse ? "text/event-stream" : "application/x-ndjson"
      json = JSON.generate(VALUE)
      frame = sse ? "data: #{json}\r\n\r\n" : "#{json}\n"
      body = (frame * EVENTS).b
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      sizes = [1, 7, 31, 1024, 4096]
      offset = 0
      index = 0
      while offset < body.bytesize
        bytes = body.byteslice(offset, sizes[index % sizes.length])
        socket.write(bytes)
        offset += bytes.bytesize
        index += 1
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Expected for early enumeration exits and rejected oversized responses.
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  config = TransportSoak::Config.new
  workload = TransportSoak::HTTPWorkload.new(config.concurrency)
  begin
    TransportSoak::Runner.new("http", config: config).run { workload.batch }
  ensure
    workload.close
  end
end
