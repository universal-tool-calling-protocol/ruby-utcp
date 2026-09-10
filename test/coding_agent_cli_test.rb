# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../examples/coding_agent"

class CodingAgentCLITest < Minitest::Test
  def setup
    @input = StringIO.new
    @out = StringIO.new
    @err = StringIO.new
    @cli = RubyUTCPAgent::CLI.new(input: @input, output: @out, error: @err, env: {})
  end

  def test_help_does_not_need_api_keys_or_load_the_sdk
    assert_equal 0, @cli.run(["--help"])
    assert_includes @out.string, "--workspace"
    assert_includes @out.string, "--codemode"
  end

  def test_invalid_options_are_reported
    assert_equal 1, @cli.run(["--not-real"])
    assert_match(/invalid option/, @err.string)
  end

  def test_missing_configuration_is_reported_without_network
    assert_equal 1, @cli.run(["--prompt", "Inspect code"])
    assert_match(/OPENROUTER_API_KEY/, @err.string)
  end
end
