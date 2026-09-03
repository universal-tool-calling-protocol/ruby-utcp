# frozen_string_literal: true

require "json"

$stdout.sync = true

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request.key?("id")

  result = case request["method"]
           when "initialize"
             {
               "protocolVersion" => "2025-06-18",
               "capabilities" => { "tools" => {} },
               "serverInfo" => { "name" => "fixture", "version" => "1.0.0" }
             }
           when "tools/list"
             {
               "tools" => [{
                 "name" => "echo",
                 "description" => "Echo an argument",
                 "inputSchema" => { "type" => "object" }
               }]
             }
           when "tools/call"
             {
               "content" => [{
                 "type" => "text",
                 "text" => JSON.generate("echo" => request.dig("params", "arguments", "message"))
               }]
             }
           else
             {}
           end
  puts JSON.generate("jsonrpc" => "2.0", "id" => request["id"], "result" => result)
end
