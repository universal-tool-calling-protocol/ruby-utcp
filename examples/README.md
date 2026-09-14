# Examples

## Coding agent with OpenRouter and Code Mode

[`coding_agent.rb`](coding_agent.rb) is a command-line coding agent using `UTCP::CodeModeUtcpClient` and OpenRouter. The model returns a fenced Ruby program that discovers workspace tools, composes calls through `codemode.call_tool`, and returns selected results with captured logs. Each program runs through `call_tool_chain`; the underlying file and command tools use UTCP's CLI transport. Results go back to the model until it finishes or reaches the turn limit. No additional runtime gems are needed.

Every prompt uses an editing workflow by default: inspect the relevant current files, implement the requested outcome on disk, and verify the changes. This also applies to short prompts such as `"Extend README.md"`; no extra editing flag or special wording is needed. Completion requires an observed file read and a verified content change. Use `--no-require-changes` for a task that may finish without edits, such as explaining the repository.

The default `--response-mode code` accepts one complete `ruby` code fence per program and a `FINAL:` report when done. It sends no function schemas to OpenRouter, so the model does not have to JSON-escape a large program or document inside a tool argument. `--response-mode tools` optionally uses native function calling with a single `execute_code` function; both formats execute the same constrained Code Mode programs and print the same trace.

The registered tool interfaces are included in the initial prompt, so the model can start useful work in its first response. `codemode.interfaces` and `codemode.search_tools` remain available. For example, it can locate relevant code and read several files in one program:

```ruby
definitions = codemode.call_tool("workspace.symbols", path: ".", query: "add", glob: "*.rb", offset: 0)
references = codemode.call_tool("workspace.grep", path: ".", pattern: "add\(", glob: "*.rb", ignore_case: false, offset: 0)
files = codemode.call_tool("workspace.read_files", files: [
  {path: "README.md", max_lines: 100},
  {path: "lib/math.rb", start_line: 1, max_lines: 200}
])
{ definitions: definitions, references: references, files: files }
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
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project --no-require-changes \
  "Inspect the project" 2>&1 | tee coding-agent.log
```

From the repository root:

```sh
bundle install
export OPENROUTER_API_KEY='your-openrouter-api-key'
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  "Inspect the project and add a small Ruby hello-world script"
```

The default model ID is `inception/mercury-2.5`; `--help` also shows the current default. To choose another model, set `OPENROUTER_MODEL` or pass `--model 'provider/model'` with an actual ID from the [model catalog](https://openrouter.ai/models). Paid models are supported, and requests have no zero-price filter. You need an API key and sufficient OpenRouter credits for the selected model. Model IDs are sent unchanged, including any routing variants you explicitly select. Native `--response-mode tools` additionally requires a model that supports function calling.

```sh
bundle exec ruby -Ilib examples/coding_agent.rb \
  --model inclusionai/ling-3.0-flash --workspace /path/to/project --no-require-changes \
  "Inspect the project and explain its structure"
```

To give the agent repository-wide context before its first model request:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  --context repository --allow-shell --max-turns 24 \
  "Refactor the parser into smaller modules, update every caller and run the relevant tests"
```

`--context repository` recursively loads the full raw contents, workspace-relative paths, and SHA-256 hashes of eligible text files into the initial conversation. This includes tracked files and untracked files that Git does not ignore. Git ignore rules apply when Git is installed and the workspace is inside a repository; plain directories also work. The model can use this snapshot immediately and use file tools for subsequent reads and changes. The default `--context tools` lets it discover and read context as needed.

Choose one context value: `--context tools` or `--context repository`. Repository mode still includes every workspace tool; `--context tools repository` does not select both modes.

Context loading skips `.git`, `.bundle`, `node_modules`, `vendor`, `.venv`, symlinks, and files named `.env` or `.env.*`. Binary, invalid UTF-8, unreadable, and files over 256 KiB are reported in `skipped_files` and the terminal log. The snapshot records its exclusion rules. Add exclusions with repeatable `--exclude-context GLOB` options: `--exclude-context 'docs/**' --exclude-context '*.lock'`. A glob with `/` matches a workspace-relative path; other globs match basenames at any depth. These exclusions apply to automatic context loading; they do not change the file tools' access rules.

The serialized snapshot defaults to a 1 MiB limit, configurable with `--max-context-bytes N`. If it exceeds that budget or the scan cannot finish within 20,000 entries, the example stops before contacting the model. It never silently sends a truncated snapshot. Increase the byte limit for a model with enough input capacity, exclude unnecessary files, choose a smaller workspace, or use `--context tools`. The byte limit is not a token estimate; the selected model must accommodate the snapshot, instructions, conversation, and requested output. The snapshot reflects files at startup, and later tool results take precedence. Included contents are sent to OpenRouter and the selected provider.

The agent can list directories, find paths recursively, search file contents, read files in batches, create, rewrite, move, and delete files, edit exact matches, and build a replacement file in chunks. File tools stay within the selected workspace, reject symlinks and `.git` paths, and limit files to 256 KiB. `read_file` accepts `max_lines` from 1 to 50,000 with a one-based `start_line`. Pages contain at most 32 KiB of complete numbered lines and return `returned_lines`, `truncated`, `next_line`, and the full file's `sha256`. Follow `next_line` until it is null; a single line larger than the page budget is reported as an error.

`find_files(path:, glob:, offset:)` returns workspace-relative paths. `search_files(path:, query:, glob:, offset:)` returns matching lines with paths and line numbers using literal, case-sensitive text. Neither tool requires `--allow-shell`. Globs containing `/` match paths relative to the search directory; a basename glob such as `*.rb` matches at any depth. Start with `offset: 0` and follow `next_offset`. Pages contain up to 200 results within a 32 KiB result budget; long matching lines return a UTF-8 excerpt around the match with `text_truncated: true`. Pagination assumes the workspace has not changed between requests.

`grep(path:, pattern:, glob:, ignore_case:, offset:)` searches using a Ruby regular expression, returning one result per matching line with `path`, one-based `line`, `text`, and `text_truncated`. Set `ignore_case: true` for case-insensitive matching. A pattern is at most 1,024 bytes and searches one line at a time. Regex matching has a 50 ms limit per line and a two-second matching budget per call; on timeout, narrow the search or simplify the pattern. Grep requires Ruby 3.2 or later for interruptible regex matching; `search_files` remains available for literal searches on older Ruby versions.

`symbols(path:, query:, glob:, offset:)` locates Ruby declarations without executing source code. It returns a `symbols` array containing `name`, `qualified_name`, `kind`, `path`, and one-based `line`. Kinds are `class`, `module`, `method`, `singleton_method`, and `constant`. Query text is a case-sensitive substring of the qualified name; use `query: ""` for all declarations. For example, `Calculator#sum` finds an instance method and `Calculator.build` finds a singleton method. Names describe lexical nesting; they do not resolve runtime constant lookup, inheritance, or computed receivers (shown as `<receiver>`).

Symbol search parses `.rb`, `.rake`, `.gemspec`, `.ru`, `Gemfile`, and `Rakefile` with the running Ruby version's parser. Invalid or unsupported Ruby syntax increments `parse_errors`; other file types increment `unsupported_files`. Both are included in `skipped_files`. It ignores declaration-like text in comments and strings. Methods generated by DSLs such as `attr_reader` or `define_method` are outside this declaration index; use grep for those definitions, references, and other languages.

Grep and symbol search accept either a file or directory as `path`, work without `--allow-shell`, and use the same globs, pagination, output budgets, and scan limits as the other search tools. No additional search program or index setup is required. The agent receives both tool interfaces at startup and is instructed to use them when inspecting and refactoring code.

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

For a shorter complete rewrite, `rewrite_file(path:, content:, expected_sha256:)` atomically replaces the file and preserves permissions. `move_file(path:, destination_path:, expected_sha256:)` moves or renames a file, creates missing parent directories, and refuses to overwrite a destination. Moves must stay on one filesystem. `delete_file(path:, expected_sha256:)` removes a single file; it cannot recursively delete directories. Each requires a matching hash from a read, snapshot, or previous modification result, so a stale request fails. Changes across multiple files are separate operations, and the agent checks results before dependent work. The tools are intended for a local workspace, not concurrent untrusted filesystem writers.

Example tasks:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  --context repository "Rewrite README.md using the current code and examples"
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  --context repository "Move the formatter into lib/formatting.rb and update all references"
```

New-file creation refuses to overwrite an existing file. Ordinary edits apply immediately. Prompts and tool results, including source code, are sent to OpenRouter and its selected provider.

The agent records successful `read_file`/`read_files` pages and repository snapshot contents. Existing-file mutations require a matching current file hash; search results and symbol listings do not count as a read. Complete replacements with `rewrite_file` or `commit_file` require all pages of the original, so an unread tail cannot be silently discarded. A stale read is rejected before the file tool runs. Read the current version and reconcile the requested change with it. Newly supplied draft content is known to the agent, so it can append chunks without rereading each one; external draft changes invalidate that state.

Every run ends with a `Workspace file changes` report based on file hashes, including creations, modifications, and deletions. File-tool operations record the original content of each affected path. Before the first shell command, the host also takes a workspace snapshot, so shell edits are counted. Existing unrelated changes, no-op writes, and edits later reverted do not count. The snapshot contains hashes only and does not send additional source to the model.

Shell change tracking scans regular files up to 256 KiB each, including binary files, within a 32 MiB read budget and a 20,000-entry scan limit. It skips `.git`, dependency directories, and symlinks like the recursive file tools. Incomplete scans and files that cannot be fingerprinted produce a separate limit notice; an unknown original file is never counted as newly created. File tools can still track paths outside the recursive scan when their original content was recorded before a shell command.

Run a rewrite or refactor directly:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project --context tools --allow-shell --max-turns 8 "Inspect and refactor at most 10 files total, including tests. Simplify structure, improve readability, and remove duplication. Preserve public behavior, run relevant tests, and summarize actual file changes."
```

`--require-changes` is enabled by default and remains accepted for compatibility. An unchanged or unverified final response triggers one request to continue, within the existing turn limit. If the model stops again without a verified content change based on a file read, the command exits with status 1 and includes its report in the error. Passing tests or a claim of completion do not satisfy this check. New-file tasks must include a read to verify the result. Shell edits can count when the edited file was read in its current state before the command; blind shell writes and later no-op edits cannot satisfy the workflow. Shell commands still have unrestricted side effects when enabled, and failing completion does not roll back those effects.

The model must preserve explicit task constraints and avoid invented bugs or unnecessary changes. A request to fix only verified bugs may find none; that run reports the limitation and exits unsuccessfully by default. Use `--no-require-changes` when an unchanged result is acceptable. The completion check verifies reads and content changes, not the semantic correctness of a refactor or bug fix.

Enable shell commands when the task needs tests or `git diff`:

```sh
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project \
  --allow-shell --max-turns 16 --max-tokens 8192 \
  "Fix the failing tests, run the relevant tests, and summarize the changes"
```

`--allow-shell` lets the model run arbitrary shell commands with your user's permissions. Their working directory is the workspace; this is **not an OS sandbox**. CLI processes inherit a small environment allow-list that excludes `OPENROUTER_API_KEY`. Commands have a 60-second timeout and return at most 32 KiB of output with their exit code. File operations need no shell opt-in.

Use `--help` for all options. The agent defaults to direct code replies, 12 model turns, and 4,096 output tokens per request; use `--max-tokens` to override that output limit. Programs and tool-argument JSON are validated before any call in the response runs. Truncated or malformed responses are discarded rather than replayed in conversation history; the model gets concise feedback requesting a smaller program. Recovery stops after three consecutive invalid responses and still respects `--max-turns`.

After each `Turn ...` message, the CLI shows that it is waiting for the model, prints elapsed wait time every five seconds, and reports retries and response time. Responses are buffered until complete so partial programs cannot run. `--request-timeout SECONDS` sets a total deadline for each model request, including connection setup, body reads, retries, and backoff; the default is 60 seconds. On timeout, the connection is closed and the agent exits without executing a program from that request. Earlier file changes persist. This is a per-request limit, not a deadline for the entire run. For smaller replies and a shorter wait, use `--max-tokens 2048 --request-timeout 45`.

OpenRouter requests reuse an HTTPS connection across turns and retries to avoid repeated connection setup. The CLI closes it on exit; programs using `OpenRouter` directly should call `close` when finished. A failed connection is discarded. Transient 408/429/500/502/503/504 errors receive at most two retries with bounded delays within the total request deadline, including provider errors inside HTTP 200 responses. Remaining failures show OpenRouter's message, code, model, and available provider/type/request details. Credentials are redacted. Other API failures, turn limits, exhausted recovery, and interruptions exit unsuccessfully so a partial run is not reported as completed. Restart an already-running agent to load changes to its response mode or limits.

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
