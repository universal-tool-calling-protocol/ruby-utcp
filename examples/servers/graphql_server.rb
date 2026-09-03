# frozen_string_literal: true

require_relative "http_helpers"

port = Integer(ENV.fetch("PORT", "8085"))

ExampleHTTP.server(port) do |server|
  server.mount_proc("/graphql") do |request, response|
    payload = ExampleHTTP.request_json(request)
    if payload["query"].to_s.include?("UTCPIntrospection")
      ExampleHTTP.json(response, {
        data: {
          __schema: {
            queryType: {
              name: "Query",
              fields: [{
                name: "hello",
                description: "Return a greeting",
                args: [{
                  name: "name",
                  description: "Person to greet",
                  defaultValue: nil,
                  type: { kind: "NON_NULL", name: nil, ofType: { kind: "SCALAR", name: "String" } }
                }],
                type: { kind: "SCALAR", name: "String" }
              }]
            },
            mutationType: nil,
            subscriptionType: nil,
            types: [{ kind: "SCALAR", name: "String", fields: nil, enumValues: nil }]
          }
        }
      })
    else
      name = payload.dig("variables", "name") || "world"
      ExampleHTTP.json(response, { data: { hello: "Hello, #{name}!" } })
    end
  end
end
