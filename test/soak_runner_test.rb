# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/soak_runner"

class SoakRunnerTest < Minitest::Test
  def config(**values)
    TransportSoak::Config.new({ "UTCP_SOAK_DURATION" => "5", "UTCP_SOAK_WARMUP" => "1",
                               "UTCP_SOAK_INTERVAL" => "1" }.merge(values.transform_keys(&:to_s)))
  end

  def memory
    { "rss_bytes" => 10_000_000, "heap_bytes" => 100_000, "live_objects" => 1000,
      "threads" => 2, "file_descriptors" => 5 }
  end

  def test_detects_growth_in_each_resource_and_accepts_the_exact_boundary
    limits = config.limits
    limits.each do |key, limit|
      baseline = memory
      at_limit = baseline.merge(key => baseline[key] + limit)
      assert_empty TransportSoak.violations([baseline, at_limit], limits)
      over_limit = baseline.merge(key => baseline[key] + limit + 1)
      errors = TransportSoak.violations([baseline, over_limit], limits)
      assert_equal 1, errors.length
      assert_includes errors.first, key
      # A transient increase after GC must not be hidden by a lower final sample.
      assert_equal errors, TransportSoak.violations([baseline, over_limit, baseline], limits)
    end
  end

  def test_runner_reports_counts_and_checks_only_after_warmup
    Dir.mktmpdir do |directory|
      output = File.join(directory, "result.json")
      now = 0.0
      runner = TransportSoak::Runner.new("test", config: config, output: output,
                                        clock: -> { now }, sampler: -> { memory })
      capture_io { runner.run { now += 1; { "requests" => 8 } } }
      report = JSON.parse(File.read(output))
      assert_equal "passed", report["status"]
      assert_equal 40, report["counts"]["requests"]
      assert_equal 5, report["counts"]["batches"]
      assert_equal 1, report["samples"].first["elapsed_seconds"]
      assert report["max_growth"].values.all?(&:zero?)
    end
  end

  def test_workload_failure_is_rethrown_and_saved_as_failure
    Dir.mktmpdir do |directory|
      output = File.join(directory, "result.json")
      runner = TransportSoak::Runner.new("test", config: config, output: output)
      capture_io do
        assert_raises(IOError) { runner.run { raise IOError, "lost response" } }
      end
      report = JSON.parse(File.read(output))
      assert_equal "failed", report["status"]
      assert_match(/lost response/, report["error"])
    end
  end

  def test_retained_memory_growth_aborts_before_duration_and_leaves_samples
    Dir.mktmpdir do |directory|
      output = File.join(directory, "result.json")
      now = 0.0
      sampler = -> { memory.merge("heap_bytes" => now * 10 * 1024 * 1024) }
      runner = TransportSoak::Runner.new("test", config: config, output: output, clock: -> { now }, sampler: sampler)
      capture_io do
        assert_raises(TransportSoak::Failure) { runner.run { now += 1; { "requests" => 8 } } }
      end
      report = JSON.parse(File.read(output))
      assert_equal "failed", report["status"]
      assert_equal 2, report["samples"].length
      assert_operator report["elapsed_seconds"], :<, 5
      assert_match(/heap_bytes/, report["error"])
    end
  end

  def test_invalid_or_uninformative_run_configuration_is_rejected
    [0, -1, "Infinity", "NaN"].each do |duration|
      assert_raises(ArgumentError) { config(UTCP_SOAK_DURATION: duration) }
    end
    assert_raises(ArgumentError) { config(UTCP_SOAK_DURATION: 3) }
    assert_raises(ArgumentError) { config(UTCP_SOAK_CONCURRENCY: 0) }
    assert_raises(ArgumentError) { config(UTCP_SOAK_CONCURRENCY: 65) }
  end

  def test_slow_batches_cannot_pass_by_counting_the_final_sample_twice
    Dir.mktmpdir do |directory|
      output = File.join(directory, "result.json")
      now = 0.0
      runner = TransportSoak::Runner.new("test", config: config, output: output,
                                        clock: -> { now }, sampler: -> { memory })
      capture_io do
        assert_raises(TransportSoak::Failure) { runner.run { now += 2; { "requests" => 8 } } }
      end
      report = JSON.parse(File.read(output))
      assert_equal "failed", report["status"]
      assert_match(/periodic samples/, report["error"])
    end
  end

  def test_memory_sampler_returns_real_process_metrics
    sample = TransportSoak::Memory.sample
    %w[rss_bytes heap_bytes live_objects threads file_descriptors].each do |name|
      assert_operator sample.fetch(name), :>, 0, name
    end
  end
end
