# Ruby UTCP coding agent

A terminal coding agent using the repository's real Ruby UTCP client for tool
discovery and invocation. It can inspect a workspace, make approved edits, and
run approved test/build commands. Optional Code Mode composes the same tools in
UTCP's restricted Ruby interpreter.

## Run

From the repository root, install the development dependencies as usual:

```sh
bundle install
export OPENROUTER_API_KEY='your-key'
export OPENROUTER_MODEL='your-tool-capable-model-id'

# Interactive session; edits and commands require approval.
bundle exec ruby -Ilib examples/coding_agent.rb --workspace /path/to/project

# One task, then exit.
bundle exec ruby -Ilib examples/coding_agent.rb \
  --workspace /path/to/project \
  --prompt 'Find the bug in the parser, add a regression test, and run the relevant tests.'

# Enable Code Mode in addition to individual tools.
bundle exec ruby -Ilib examples/coding_agent.rb \
  --workspace /path/to/project --codemode \
  --prompt 'Inspect the README and source, fix the outdated usage example, and verify it.'

# Inspect without granting edits or command execution.
bundle exec ruby -Ilib examples/coding_agent.rb \
  --workspace /path/to/project --read-only \
  --prompt 'Review the error handling and report concrete problems.'
```

Choose a model that supports tool calling. There is intentionally no hardcoded
model ID. `--model` overrides `OPENROUTER_MODEL` (or `LLM_MODEL`). The example does
not load `.env` files. Source snippets and command output are sent to the selected
LLM provider, which may incur charges.

For an OpenRouter-compatible local endpoint, pass the API **base** URL, not the
full `/chat/completions` URL:

```sh
LLM_API_KEY='' bundle exec ruby -Ilib examples/coding_agent.rb \
  --base-url http://127.0.0.1:1234/v1 --model your-local-model \
  --workspace /path/to/project --read-only --prompt 'Explain the project structure.'
```

`LLM_API_KEY` takes precedence over `OPENROUTER_API_KEY`.
`UTCP_AGENT_BASE_URL` supplies the default for `--base-url`. Remote endpoints must
use HTTPS. Plain HTTP and an empty API key are accepted only for loopback hosts.

In the interactive session, `/reset` clears conversation history, and `/exit`
(or `/quit`) exits. Each new task gets its own iteration and tool-call budget.

## Tools and UTCP integration

| Canonical UTCP name | Purpose |
| --- | --- |
| `workspace.list_files` | Bounded file listing, excluding common generated folders and protected names |
| `workspace.read_file` | UTF-8 file content, line ranges, and the full-file SHA-256 |
| `workspace.search` | Literal text search with paths and line numbers |
| `workspace.write_file` | Create or atomically replace a file after approval |
| `workspace.replace_text` | Replace one unique literal block after approval |
| `workspace.run_command` | Execute an approved argv array and capture output, exit status, and timeout state |

`WorkspaceClient` subclasses `UTCP::Client`, registers an example-local
`coding_agent_local` protocol and a `workspace` manual, and dispatches calls with
`Client#call_tool`. This is an **in-process custom protocol**, not a new SDK
transport, HTTP server, CLI transport, or MCP wrapper. It leaves existing SDK
protocols unchanged. A protocol instance is stateless; workspace permissions and
tool budgets belong to each client.

The LLM-facing function names use underscores (`workspace_read_file`) for provider
compatibility. The agent maps these aliases to the canonical dotted UTCP names.
It obtains descriptions and input schemas from `client.list_tools` rather than
maintaining a separate LLM-only schema registry.

With `--codemode`, the model also receives `codemode_run_code`, routed through
`UTCP::CodeMode.new(client).execute`. A typical tool chain is:

```ruby
before = codemode.call_tool("workspace.read_file", {"path" => "README.md"})
codemode.call_tool("workspace.replace_text", {
  "path" => "README.md",
  "old_text" => "an outdated command",
  "new_text" => "the corrected command",
  "expected_sha256" => before["sha256"]
})
```

The last expression is returned. The restricted interpreter does not provide
arbitrary Ruby execution; operations go through the same approved workspace
tools. Code Mode batches are **not transactions**. An earlier successful edit is
not undone when a later operation fails. Its 120-second timeout also includes
time spent at approval prompts.

## Approval and limits

By default, file writes/replacements and **every command** require terminal
approval. The prompt shows the path and before/after content, or the exact argv,
working directory, and timeout. Long previews are explicitly marked as truncated.
Noninteractive input cannot grant approval implicitly: operations are denied
unless `--yes` was explicitly supplied.

`--yes` auto-approves edits **and arbitrary command execution**. Use it only in a
trusted, disposable checkout or a properly isolated container. `--read-only`
always wins over `--yes` and also blocks commands, because test/build programs can
mutate files or access the network.

Existing-file edits require `expected_sha256` from `read_file`. The agent checks
the revision before and after approval and again immediately before replacement.
A stale revision is an error, not a silent overwrite. New files omit the revision.
No-op writes return `changed: false` without claiming a modification.

The example rejects absolute paths, `..`, symlinks, hardlinked files, `.git`, `.env*`,
`.ssh`, `.aws`, `.gnupg`, `id_rsa`, `id_ed25519`, `*.pem`, and `*.key` through its
file tools. These are conservative name-based exclusions, **not comprehensive
secret detection**. Listing also skips common dependency/build directories; it
does not interpret `.gitignore`.

These checks are **not an OS security sandbox**. An approved command can access
anything permitted to your user account, including paths outside the workspace,
network services, and credentials stored on disk. Repository tests can execute
arbitrary code. Commands do not inherit the full agent environment, so provider
API keys are not automatically passed to subprocesses; allowed variables are
`PATH`, `HOME`, `LANG`, `LC_ALL`, and `TMPDIR`. Do not use the example on a workspace
that is concurrently being modified by an untrusted process: path/revision checks
cannot eliminate all filesystem races. Review changes with your normal tools
before committing. The agent never automatically commits or pushes changes.

Defaults and hard bounds:

- 12 LLM iterations per task (`--max-turns`, between 1 and 100), 8 function calls
  per model response, and 64 underlying workspace calls per task, including Code Mode.
- 1 MiB text files; 32 KiB read/command output; 1,000 listed files; 50 search matches.
- 30-second commands by default, with a maximum of 120 seconds. The process group
  is terminated on timeout, and output is drained without retaining excess bytes.
- Code Mode: 5,000 interpreter steps and 120 seconds per execution. Large tool
  results and conversation histories are bounded; use `/reset` for a fresh task.

The CLI targets Linux/macOS (POSIX process groups) and uses Ruby standard libraries
plus this SDK. It is a synchronous example, not a production multi-user agent.
There is no streaming, persistent chat history, automatic rollback, or automatic
HTTP retry. Tool/parse errors are returned to the model for correction. Provider
errors and incomplete completions are reported rather than treated as success.
Exit codes are `0` for a normally completed conversation, `1` for an error, `2`
for the iteration limit, and `130` for interruption. A normal model answer is not
an independent guarantee that its claims are correct; inspect the tool evidence.

## Tests

```sh
# All coding-agent tests, including a real SDK + Code Mode integration subprocess.
bundle exec ruby -Ilib -Itest -e \
  'Dir["test/coding_agent_*_test.rb"].sort.each { |file| require File.expand_path(file) }'

# Existing repository suite also discovers these tests automatically.
bundle exec rake test
```

No external LLM calls or API keys are required for tests. The HTTP tests use a real
local TCP server; the agent-loop tests use explicit provider/client test doubles;
the integration test separately uses the actual UTCP client and Code Mode. The
integration runs in a subprocess to avoid modifying other tests' protocol registry.
