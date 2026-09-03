# frozen_string_literal: true

require_relative "test_helper"

class MigrationTest < Minitest::Test
  def test_migrates_v0_1_config_to_v1_1_templates
    old = {
      providers: [
        { name: "weather", provider_type: "http", url: "https://example.com", method: "POST" },
        { name: "files", provider_type: "cli", command: "cat", args: ["${filename}"], cwd: "/tmp" }
      ],
      variables: { API_KEY: "secret" }
    }

    migrated = UTCP::Migration.config_v0_1_to_v1_1(old)

    assert_nil migrated["providers"]
    assert_equal "POST", migrated["manual_call_templates"][0]["http_method"]
    cli = migrated["manual_call_templates"][1]
    assert_equal "cli", cli["call_template_type"]
    assert_equal "/tmp", cli["working_dir"]
    assert_includes cli["commands"][0]["command"], "UTCP_ARG_filename_UTCP_END"
    assert_equal({ "API_KEY" => "secret" }, migrated["variables"])
    assert old.key?(:providers), "migration must not mutate its input"
  end

  def test_migrates_v0_1_manual_models
    old = {
      utcp_version: "0.1.0",
      provider_info: { name: "Weather", version: "3.0" },
      tools: [{
        name: "forecast",
        parameters: { type: "object" },
        provider: { provider_type: "http", url: "https://example.com/f", method: "GET" }
      }]
    }

    migrated = UTCP::Migration.manual_v0_1_to_v1_1(old)
    manual = UTCP::Manual.from_h(migrated)

    assert_equal "1.1.1", manual.utcp_version
    assert_equal "Weather", manual.info["title"]
    assert_equal "object", manual.tools.first.inputs.type
    assert_instance_of UTCP::HttpCallTemplate, manual.tools.first.tool_call_template
  end

  def test_detects_legacy_manual
    assert UTCP::Migration.v0_1_manual?("tools" => [{ "provider" => {} }])
    refute UTCP::Migration.v0_1_manual?("tools" => [{ "tool_call_template" => {} }])
  end
end

