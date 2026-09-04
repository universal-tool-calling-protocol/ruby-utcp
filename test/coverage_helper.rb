# frozen_string_literal: true

require "coverage"

Coverage.start(lines: true, branches: true)

Minitest.after_run do
  library_root = File.expand_path("../lib/", __dir__) + File::SEPARATOR
  files = Coverage.result.select { |path, _data| path.start_with?(library_root) }
  lines = files.values.flat_map { |data| data[:lines].compact }
  branches = files.values.flat_map { |data| data[:branches].values.flat_map(&:values) }
  totals = { "line" => lines, "branch" => branches }
  minimums = { "line" => 80.0, "branch" => 60.0 }
  failures = []

  totals.each do |kind, counts|
    covered = counts.count { |count| count.positive? }
    percent = counts.empty? ? 0.0 : 100.0 * covered / counts.length
    puts format("%s coverage: %.1f%% (%d/%d)", kind.capitalize, percent, covered, counts.length)
    failures << "#{kind} coverage is below #{minimums[kind]}%" if percent < minimums[kind]
  end
  abort failures.join("\n") unless failures.empty?
end
