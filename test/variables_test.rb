# frozen_string_literal: true

require_relative "test_helper"

class VariablesTest < Minitest::Test
  def test_substitution_prefers_namespaced_then_direct_variables
    config = UTCP::ClientConfig.new(
      variables: { "my__api_TOKEN" => "scoped", "HOST" => "example.com" }
    )
    substitutor = UTCP::VariableSubstitutor.new

    result = substitutor.substitute(
      { "url" => "https://${HOST}/$TOKEN", "schema" => "#/$ref/value" },
      config,
      "my_api"
    )

    assert_equal "https://example.com/scoped", result["url"]
    assert_equal "#/$ref/value", result["schema"]
  end

  def test_required_variable_discovery_uses_namespace
    names = UTCP::VariableSubstitutor.new.find_required_variables(
      ["${TOKEN}", "$HOST", "${TOKEN}"],
      "my_api"
    )

    assert_equal %w[my__api_TOKEN my__api_HOST].sort, names.sort
  end

  def test_missing_variable_raises_specific_error
    config = UTCP::ClientConfig.new
    error = assert_raises(UTCP::VariableNotFoundError) do
      UTCP::VariableSubstitutor.new.substitute("${MISSING}", config, "demo")
    end

    assert_equal "demo_MISSING", error.variable_name
  end

  def test_dotenv_loader_parses_quotes_exports_and_comments
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, ".env"), <<~ENVFILE)
        # comment
        export TOKEN="hello\\nworld"
        PLAIN=value # trailing comment
        SINGLE='literal value'
      ENVFILE
      loader = UTCP::DotenvVariableLoader.new(root_dir: directory)

      assert_equal "hello\nworld", loader.get("TOKEN")
      assert_equal "value", loader.get("PLAIN")
      assert_equal "literal value", loader.get("SINGLE")
    end
  end

  def test_client_config_loads_safe_yaml
    Dir.mktmpdir do |directory|
      path = File.join(directory, "utcp.yml")
      File.write(path, "variables:\n  HOST: example.com\nmanual_call_templates: []\n")
      config = UTCP::ClientConfig.from(path, root_dir: directory)

      assert_equal "example.com", config.variables["HOST"]
    end
  end
end

