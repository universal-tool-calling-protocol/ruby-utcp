# Examples

## Coding agent with OpenRouter and Code Mode

[`coding_agent.rb`](coding_agent.rb) is a command-line coding agent using `UTCP::CodeModeUtcpClient` and OpenRouter. The model returns a fenced Ruby program that discovers workspace tools, composes calls through `codemode.call_tool`, and returns selected results with captured logs. Each program runs through `call_tool_chain`; the underlying file and command tools use UTCP's CLI transport. Results go back to the model until it finishes or reaches the turn limit. No additional runtime gems are needed.

The default `--response-mode code` accepts one complete `ruby` code fence per program and a `FINAL:` report when done. It sends no function schemas to OpenRouter, so the model does not have to JSON-escape a large program or document inside a tool argument. `--response-mode tools` optionally uses native function calling with a single `execute_code` function; both formats execute the same constrained Code Mode programs and print the same trace.

The registered tool interfaces are included in the initial prompt, so the model can start useful work in its first response. `codemode.interfaces` and `codemode.search_tools` remain available. For example, it can locate relevant code and read several files in one program:

```ruby
matches = codemode.call_tool("workspace.search_files", path: ".", query: "def add", glob: "*.rb", offset: 0)
files = codemode.call_tool("workspace.read_files", files: [
  {path: "README.md", max_lines: 100},
  {path: "lib/math.rb", start_line: 1, max_lines: 200}
])
{ matches: matches, files: files }
```

The agent includes the library's Code Mode prompt in its system instructions. Programs use fresh variables on each call and have a 60-second deadline, a 10,000-step limit, and the library's code/value/log size limits. They run in the constrained interpreter without `eval`, direct filesystem access, imports, or process access. Effects of completed tool calls persist if a later statement fails; errors remind the model to inspect the workspace before retrying.

Code Mode currently preserves backslash escapes in string literals. The agent is instructed to use single-quoted heredocs for generated source and commands containing quotes, so literal newlines and file contents survive correctly:

```ruby
content = <<~'SOURCE'
  puts "Hello from Ruby"
SOURCE
codemode.call_tool("workspace.write_file", path: "hello.rb", content: content)
```

Every run prints the generated Code Mode programs, numbered tool steps with their full arguments and outputs, tool-search results, captured logs, final program results, and errors. Tool output appears as each call finishes, including intermediate results the program does not return. Streaming calls print each chunk. This trace goes to stderr; model responses go to stdout. To keep a combined transcript:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  "Inspect the project" 2>&1 | tee coding-agent.log
```

From the repository root:

```sh
bundle install
export OPENROUTER_API_KEY='your-openrouter-api-key'
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  "Inspect the project and add a small Ruby hello-world script"
```

The default model is [`inclusionai/ling-3.0-flash`](https://openrouter.ai/inclusionai/ling-3.0-flash). To choose another model, set `OPENROUTER_MODEL` or pass `--model 'provider/model'` with an actual ID from the [model catalog](https://openrouter.ai/models). Paid models are supported, and requests have no zero-price filter. You need an API key and sufficient OpenRouter credits for the selected model. Model IDs are sent unchanged, including any routing variants you explicitly select. Native `--response-mode tools` additionally requires a model that supports function calling.

```sh
bundle exec ruby -Ilib examples/coding_agent.rb \
  --model inclusionai/ling-3.0-flash --workspace /path/to/project \
  "Inspect the project and explain its structure"
```

The agent can list directories, find paths recursively, search file contents, read files in batches, create files, edit exact matches, and build a replacement file in chunks. File tools stay within the selected workspace, reject symlinks and `.git` paths, and limit files to 256 KiB. `read_file` accepts `max_lines` from 1 to 50,000 with a one-based `start_line`. Pages contain at most 32 KiB of complete numbered lines and return `returned_lines`, `truncated`, `next_line`, and the full file's `sha256`. Follow `next_line` until it is null; a single line larger than the page budget is reported as an error.

`find_files(path:, glob:, offset:)` returns workspace-relative paths. `search_files(path:, query:, glob:, offset:)` returns matching lines with paths and line numbers using literal, case-sensitive text. Neither tool requires `--allow-shell`. Globs containing `/` match paths relative to the search directory; a basename glob such as `*.rb` matches at any depth. Start with `offset: 0` and follow `next_offset`. Pages contain up to 200 results within a 32 KiB result budget; long matching lines return a UTF-8 excerpt around the match with `text_truncated: true`. Pagination assumes the workspace has not changed between requests.

Recursive scans skip `.git`, `.bundle`, `node_modules`, `vendor`, `.venv`, and symlinks. They visit at most 20,000 entries, and text search reads at most 32 MiB per call. Binary, oversized, and unreadable files are skipped and counted in `skipped_files`. When `scan_truncated` is true, narrow the path or glob; an incomplete search cannot establish that text is absent. These tools do not interpret `.gitignore`.

`read_files(files:)` reads up to eight independent pages in one CLI process. Each item has a `path` and optional `start_line` and `max_lines` (defaults: 1 and 200). It divides a 32 KiB content budget among the requested files, returning per-file errors, hashes, and continuation lines. Continue an individual page with `read_file`. This avoids launching a Ruby process for each file in a batch.

For several changes to one file, `edit_file_batch` validates its saved hash, applies all replacements in memory, and atomically saves once. If any match is missing or ambiguous, the file remains unchanged. Replacements run in order and must each match exactly once. The result includes the new hash, and the original permissions are preserved:

```ruby
source = codemode.call_tool("workspace.read_file", path: "lib/math.rb", start_line: 1, max_lines: 200)
if source["error"]
  source
else
  codemode.call_tool("workspace.edit_file_batch", path: "lib/math.rb", expected_sha256: source["sha256"], edits: [
    {old_text: "a - b", new_text: "a + b"},
    {old_text: "def add", new_text: "def sum"}
  ])
end
```

For a long README rewrite, the model is instructed to read the original and create an unused draft beside it with `write_file`, then add small sections with `append_file`. Each append checks `expected_bytes` against the previous result's `total_bytes` to avoid duplicating a retried chunk. After reviewing the draft, `commit_file` checks the original's saved SHA-256 and atomically renames the draft over it, preserving permissions. A changed original rejects the commit. The original remains intact while the draft is built, and a successful commit removes the draft path. This avoids generating the entire old and new document in one model response.

New-file creation refuses to overwrite an existing file. Ordinary edits apply immediately. Prompts and tool results, including source code, are sent to OpenRouter and its selected provider.

Enable shell commands when the task needs tests or `git diff`:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  --allow-shell --max-turns 16 --max-tokens 8192 \
  "Fix the failing tests, run the relevant tests, and summarize the changes"
```

`--allow-shell` lets the model run arbitrary shell commands with your user's permissions. Their working directory is the workspace; this is **not an OS sandbox**. CLI processes inherit a small environment allow-list that excludes `OPENROUTER_API_KEY`. Commands have a 60-second timeout and return at most 32 KiB of output with their exit code. File operations need no shell opt-in.

Use `--help` for all options and the current output-token default. The agent defaults to direct code replies and 12 model turns; use `--max-tokens` to set the output-token limit for your selected model. Programs and tool-argument JSON are validated before any call in the response runs. Truncated or malformed responses are discarded rather than replayed in conversation history; the model gets concise feedback requesting a smaller program. Recovery stops after three consecutive invalid responses and still respects `--max-turns`.

OpenRouter requests reuse an HTTPS connection across turns and retries to avoid repeated connection setup. The CLI closes it on exit; programs using `OpenRouter` directly should call `close` when finished. A failed connection is discarded. Transient 408/429/500/502/503/504 errors receive at most two retries with bounded delays, including provider errors inside HTTP 200 responses. Remaining failures show OpenRouter's message, code, model, and available provider/type/request details. Credentials are redacted. Other API failures, turn limits, exhausted recovery, and interruptions exit unsuccessfully so a partial run is not reported as completed. Restart an already-running agent to load changes to its response mode or limits.

The example is intentionally separate from `make demo` and `make examples`, since it requires credentials and can modify a project. Its offline integration tests use a scripted model with the real Code Mode interpreter and UTCP CLI tool execution:

```sh
bundle exec ruby -Itest test/coding_agent_test.rb
```

## Transport examples

Each official transport has a client example. Network transports include a matching local server under `examples/servers`:

| Transport | Client | Matching server |
| --- | --- | --- |
| HTTP | `http.rb` | `servers/http_server.rb` |
| SSE | `sse.rb` | `servers/sse_server.rb` |
| Streamable HTTP | `streamable_http.rb` | `servers/streamable_http_server.rb` |
| CLI | `cli.rb` | self-contained |
| WebSocket | `websocket.rb` | `servers/websocket_server.rb` |
| gRPC | `grpc.rb`, `grpc_python.py` | `servers/grpc_server.rb` or `servers/grpc_server.py` |
| GraphQL | `graphql.rb` | `servers/graphql_server.rb` |
| TCP | `tcp.rb` | `servers/tcp_server.rb` |
| UDP | `udp.rb` | `servers/udp_server.rb` |
| WebRTC | `webrtc.rb` | `servers/webrtc_server.rb` |
| MCP | `mcp.rb` | `servers/mcp_stdio_server.rb`, launched by the client |
| Text | `text.rb` | self-contained |

## Code Mode

`code_mode.rb` uses `CodeModeUtcpClient` to discover a tool, call it twice through `codemode.call_tool`, transform both responses inside the constrained Ruby runtime, and print the result with captured logs. It reuses the HTTP example server:

```sh
ruby -Ilib examples/servers/http_server.rb
ruby -Ilib examples/code_mode.rb
```

The example is also included in `make examples`, `make demo`, and the corresponding `full-*` targets.

For a network example, start the server in one terminal and the client in another:

```sh
ruby -Ilib examples/servers/http_server.rb
ruby -Ilib examples/http.rb
```

Replace `http` with `sse`, `streamable_http`, `websocket`, `graphql`, `tcp`, or `udp` for the other standard-library pairs. The MCP client starts its stdio server automatically. CLI and text run without a server:

```sh
ruby -Ilib examples/cli.rb
ruby -Ilib examples/text.rb
```

The HTTP-family and GraphQL servers use WEBrick. On Ruby versions where it is not bundled, add `gem "webrick"`. The gRPC pair additionally needs `gem "grpc"`. The WebRTC pair needs Ruby 3.1+, `gem "webrtc-ruby"`, and a working `libdatachannel` installation.

The Python server and client import the checked-in `utcp_pb2.py` and `utcp_pb2_grpc.py` stubs from `examples/generated`. Regenerate both files from [`proto/utcp.proto`](../proto/utcp.proto) with `protoc` after changing the contract:

```sh
make grpc-python-setup    # create .venv-grpc, install dependencies, generate stubs
make grpc-python-generate # regenerate stubs with grpc_tools.protoc
make grpc-python-server  # server only, on 127.0.0.1:50051
make grpc-python-client  # generated-stub Python client; server must be running
make grpc-python-demo    # start server, run Ruby + Python clients, stop server
```

All servers bind only to `127.0.0.1`. Set `PORT` on a server and the corresponding `UTCP_*` environment variable on its client to change an endpoint.

To run everything together, use the repository `Makefile`:

```sh
make                 # run every available pair; report and skip missing optional backends
make full-demo       # require dependencies, then run all 12 examples
make servers         # keep every available network server running until Ctrl-C
make full-servers    # require dependencies, then keep every server running
make examples        # run available clients against servers that are already running
make full-examples   # require dependencies, then run all 12 clients
make standard-demo   # skip native gRPC and WebRTC pairs
make grpc-python-demo # run the Ruby client against the Python gRPC server
make test
```

`make`, `make servers`, and `make examples` detect gRPC and WebRTC independently. If an optional backend is absent, they skip only that pair. The `full-*` targets fail early with an installation hint unless all dependencies are available. WebRTC requires Ruby 3.1+.
