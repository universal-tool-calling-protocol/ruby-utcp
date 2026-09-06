# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

desc "Soak test with memory/resource limits: rake soak[http] or soak[webrtc]"
task :soak, [:scenario] do |_task, arguments|
  require_relative "test/support/soak_runner"
  require "timeout"
  scenario = arguments[:scenario] || "http"
  abort "Scenario must be http or webrtc" unless %w[http webrtc].include?(scenario)
  config = TransportSoak::Config.new
  report = ENV.fetch("UTCP_SOAK_REPORT", "tmp/soak/#{scenario}.json")
  FileUtils.mkdir_p(File.dirname(report))
  File.write(report, JSON.pretty_generate("scenario" => scenario, "status" => "starting") + "\n")
  environment = { "UTCP_SOAK_REPORT" => report }
  command = [RbConfig.ruby, "-Itest"]
  if scenario == "webrtc"
    environment["UTCP_NATIVE_SOAK"] = "1"
    command.concat(["test/integration/native_transports.rb", "--name", "/\\Atest_native_webrtc_soak\\z/"])
  else
    command << "test/integration/transport_soak.rb"
  end
  pid = Process.spawn(environment, *command, pgroup: true)
  reaped = false
  begin
    _pid, status = Timeout.timeout(config.duration + 60) { Process.wait2(pid) }
    reaped = true
    data = JSON.parse(File.read(report))
    unless status.success? && data["status"] == "passed"
      data["status"] = "failed"
      data["error"] ||= "Subprocess exited with #{status.exitstatus.inspect} or did not finish the scenario"
      File.write(report, JSON.pretty_generate(data) + "\n")
      abort "#{scenario} soak failed"
    end
  rescue Timeout::Error
    data = File.file?(report) ? JSON.parse(File.read(report)) : { "scenario" => scenario }
    data.merge!("status" => "failed", "error" => "Subprocess watchdog expired, including cleanup")
    FileUtils.mkdir_p(File.dirname(report))
    File.write(report, JSON.pretty_generate(data) + "\n")
    abort "#{scenario} soak exceeded #{config.duration + 60} seconds (including cleanup)"
  ensure
    unless reaped
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end

task default: :test

desc "Run tests with line and branch coverage thresholds"
task :coverage do
  sh({ "COVERAGE" => "1" }, RbConfig.ruby, "-Itest", "-e",
     'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }')
end

desc "Test real gRPC and WebRTC backends (requires optional native gems)"
task :native do
  require "timeout"
  require "shellwords"
  # A native deadlock can hold Ruby's GVL, so the watchdog must live in the parent.
  pid = Process.spawn(RbConfig.ruby, "-Itest", "test/integration/native_transports.rb",
                      *Shellwords.split(ENV.fetch("TESTOPTS", "")))
  begin
    _pid, status = Timeout.timeout(45) { Process.wait2(pid) }
    abort "Native integration tests failed" unless status.success?
  rescue Timeout::Error
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
    abort "Native integration timed out after 45 seconds (including backend cleanup)"
  end
end
