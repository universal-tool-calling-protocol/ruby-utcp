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
