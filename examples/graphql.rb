# frozen_string_literal: true

require "utcp"

# Registration runs GraphQL introspection and turns root fields into UTCP tools.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "local_graph",
    call_template_type: "graphql",
    url: ENV.fetch("UTCP_GRAPHQL_URL", "http://localhost:8085/graphql")
  }]
})

puts client.list_tools.map(&:name)
puts client.call_tool("local_graph.hello", name: "Ruby").inspect
