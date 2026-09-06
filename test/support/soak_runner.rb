# frozen_string_literal: true

require "json"
require "objspace"
require "open3"
require "fileutils"
require "time"

# Samples at quiescent batch boundaries after GC. RSS includes native memory;
# heap bytes and live slots distinguish retained Ruby objects from allocator slack.
module TransportSoak
  class Failure < StandardError; end

  class Config
    attr_reader :duration, :warmup, :interval, :concurrency, :requests_per_second, :limits

    def initialize(env = ENV)
      @duration = number(env, "UTCP_SOAK_DURATION", 300)
      @warmup = number(env, "UTCP_SOAK_WARMUP", 30, allow_zero: true)
      @interval = number(env, "UTCP_SOAK_INTERVAL", 10)
      @concurrency = Integer(env.fetch("UTCP_SOAK_CONCURRENCY", 8))
      @requests_per_second = number(env, "UTCP_SOAK_REQUESTS_PER_SECOND", 200, allow_zero: true)
      raise ArgumentError, "concurrency must be between 1 and 64" unless (1..64).cover?(@concurrency)
      raise ArgumentError, "duration must allow warmup and at least three sample intervals" if @duration < @warmup + 3 * @interval
      @limits = {
        "rss_bytes" => number(env, "UTCP_SOAK_RSS_GROWTH_MIB", 32) * 1024 * 1024,
        "heap_bytes" => number(env, "UTCP_SOAK_HEAP_GROWTH_MIB", 8) * 1024 * 1024,
        "live_objects" => number(env, "UTCP_SOAK_OBJECT_GROWTH", 20_000),
        "threads" => number(env, "UTCP_SOAK_THREAD_GROWTH", 4, allow_zero: true),
        "file_descriptors" => number(env, "UTCP_SOAK_FD_GROWTH", 4, allow_zero: true)
      }
    end

    def to_h
      { "duration_seconds" => duration, "warmup_seconds" => warmup, "sample_interval_seconds" => interval,
        "concurrency" => concurrency, "requests_per_second" => requests_per_second, "max_growth" => limits }
    end

    private

    def number(env, key, default, allow_zero: false)
      value = Float(env.fetch(key, default))
      valid = value.finite? && (allow_zero ? value >= 0 : value > 0)
      raise ArgumentError, "#{key} must be finite and #{allow_zero ? 'non-negative' : 'positive'}" unless valid
      value
    end
  end

  module Memory
    module_function

    def sample
      GC.start(full_mark: true, immediate_sweep: true)
      heap_bytes = ObjectSpace.memsize_of_all
      live_objects = GC.stat(:heap_live_slots)
      threads = Thread.list.count(&:alive?)
      fd_directory = File.directory?("/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
      descriptors = Dir.children(fd_directory).length
      rss = if File.file?("/proc/self/status")
              Integer(File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1]) * 1024
            else
              output, status = Open3.capture2("ps", "-o", "rss=", "-p", Process.pid.to_s)
              raise Failure, "Cannot measure resident memory" unless status.success?
              Integer(output.strip) * 1024
            end
      { "rss_bytes" => rss, "heap_bytes" => heap_bytes, "live_objects" => live_objects,
        "threads" => threads, "file_descriptors" => descriptors }
    end
  end

  def self.growth(samples)
    return {} if samples.empty?
    samples.first.reject { |key, _| key == "elapsed_seconds" }.each_with_object({}) do |(key, baseline), values|
      values[key] = [samples.map { |sample| sample.fetch(key) }.max - baseline, 0].max
    end
  end

  def self.violations(samples, limits)
    growth(samples).map do |key, increase|
      "#{key} grew by #{increase}, limit #{limits.fetch(key)}" if increase > limits.fetch(key)
    end.compact
  end

  class Runner
    def initialize(scenario, config: Config.new, output: nil, sampler: -> { Memory.sample }, clock: nil)
      @scenario = scenario
      @config = config
      @output = output || ENV.fetch("UTCP_SOAK_REPORT", "tmp/soak/#{scenario}.json")
      @sampler = sampler
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @samples = []
      @counts = Hash.new(0)
    end

    def run
      @started = @clock.call
      @report = { "schema_version" => 1, "scenario" => @scenario, "status" => "running",
                  "ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM, "pid" => Process.pid,
                  "started_at" => Time.now.utc.iso8601, "config" => @config.to_h }
      next_sample = @config.warmup
      periodic_samples = 0
      loop do
        batch_started = @clock.call
        counts = yield
        counts.each { |key, value| @counts[key.to_s] += Integer(value) }
        @counts["batches"] += 1
        if @config.requests_per_second.positive?
          requests = counts["requests"] || counts[:requests] || 0
          pause = requests / @config.requests_per_second - (@clock.call - batch_started)
          sleep pause if pause.positive?
        end
        elapsed = @clock.call - @started
        if elapsed >= next_sample
          sample!
          periodic_samples += 1
          next_sample = elapsed + @config.interval
        end
        break if elapsed >= @config.duration
      end
      sample!
      if periodic_samples < 4
        raise Failure, "Fewer than four periodic samples; reduce batch duration or increase soak duration"
      end
      @report["status"] = "passed"
      @report
    rescue Exception => error # Always leave a failure report, including interrupted/native load failures.
      @report ||= { "scenario" => @scenario }
      @report["status"] = "failed"
      @report["error"] = "#{error.class}: #{error.message}"
      raise
    ensure
      if @report
        write_report
        puts "Soak #{@scenario}: #{@report['status']}; report #{@output}"
      end
    end

    private

    def sample!
      sample = @sampler.call.merge("elapsed_seconds" => (@clock.call - @started).round(3))
      @samples << sample
      puts JSON.generate("scenario" => @scenario, "counts" => @counts, "sample" => sample)
      STDOUT.flush
      write_report
      errors = TransportSoak.violations(@samples, @config.limits)
      raise Failure, errors.join("; ") unless errors.empty?
    end

    def write_report
      @report.merge!("elapsed_seconds" => @clock.call - @started, "counts" => @counts,
                     "samples" => @samples, "max_growth" => TransportSoak.growth(@samples))
      FileUtils.mkdir_p(File.dirname(@output))
      temporary = "#{@output}.tmp"
      File.write(temporary, JSON.pretty_generate(@report) + "\n")
      File.rename(temporary, @output)
    end
  end

  def self.parallel(count)
    workers = count.times.map do |index|
      Thread.new { yield index }.tap { |worker| worker.report_on_exception = false }
    end
    workers.map(&:value)
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end
end
