# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
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
