# qwen-agent

`qwen-agent` runs persistent Qwen coding workers through Claude Code and
Alibaba Cloud Model Studio's Anthropic-compatible endpoint (Token Plan). It
ships as a Bash CLI and as a Claude Code plugin, and shares its engine with
the other providers in this repository.

A worker keeps one Claude session, working directory, and model across `start`
and later `send` calls. A headless turn runs synchronously, or as a detached
operation that the worker ID recovers. The CLI prints compact control-plane
output for an orchestrator. Prompts, durable reports, raw Claude responses,
and stderr stay on disk.

| Component | What it does |
| --- | --- |
| `qwen-agent` | Creates, resumes, observes, cancels, and closes workers |
| `qwen-dispatch` | Sends one task to a worker, waits, and prints a verdict |
| `qwen-agent:dispatch` | Skill that tells the main session how to call `qwen-dispatch` |
| `qwen-agent:explorer`, `qwen-agent:general-purpose` | Bridge agents that route a task to a worker |

## Requirements

- Bash 3.2 or newer
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) available as
  `claude`
- `jq`
- A Model Studio API key for the Token Plan (personal or team)
- macOS or a Unix-like environment

## Installation

Install the plugin from this repository's marketplace:

```bash
claude plugin marketplace add powdream-org/provider-agent
claude plugin install qwen-agent@provider-agent --scope user
```

The plugin provides the bridge agents `qwen-agent:explorer` and
`qwen-agent:general-purpose`, the skill `qwen-agent:dispatch`, and the script
`qwen-dispatch`.

### Standalone CLI

Clone the repository and run the script from the checkout:

```bash
git clone https://github.com/powdream-org/provider-agent.git
bash /path/to/provider-agent/qwen/qwen-agent --help
```

To install the CLI elsewhere, copy the `qwen/` directory and the shared
`core/` directory together, keeping their relative layout.

## Configure the API key

`qwen-agent` stores each Model Studio credential as a named account under
`~/.qwen/accounts/<name>/`. One account is active at a time, and every
command that needs a key uses the active account.

The stored key is the only key source: `qwen-agent` never reads the
`QWEN_API_KEY` environment variable, and strips it from the Claude process
environment.

Add an account:

```bash
qwen-agent auth add personal --name me --api-key "<key>"
```

`auth add` never changes the active account. It prints a receipt:

```text
ACCOUNT=ADDED
NAME=me
TYPE=personal
ACTIVE=false
```

- A name matches `[A-Za-z0-9][A-Za-z0-9._@-]*`, so an email address such as
  `me@example.com` works. An existing name is an error.
- A key given as `--api-key "<key>"` can appear in shell history and process
  listings. `--api-key -` reads one line from stdin instead:

  ```bash
  qwen-agent auth add personal --name me --api-key - < key.txt
  ```

Make an account active:

```bash
qwen-agent auth switch me
```

```text
ACCOUNT=ACTIVE
NAME=me
TYPE=personal
```

- `~/.qwen/.env.auth` is a relative symlink to the active account's key.
- The active account name is the `.env.auth` link target. No other file
  stores it.

List the accounts, sorted by name in byte order, and mark the active one:

```bash
qwen-agent auth list
```

Remove an account. `auth remove` refuses the active account, so switch first:

```bash
qwen-agent auth remove me
```

```text
ACCOUNT=REMOVED
NAME=me
```

No `auth` output ever contains a key. `~/.qwen/accounts/` and each account
directory have mode `0700`. The key file has mode `0600`.

`qwen-agent api-key [key]` still works. While an account is active, it
replaces the key of that account and keeps the link. Without an active
account, it writes a plain `~/.qwen/.env.auth` file. A hidden interactive
prompt keeps the key out of shell history:

```bash
qwen-agent api-key
```

## Verified configuration

The wrapper preserves this Alibaba Cloud Model Studio configuration:

| Setting | Value |
| --- | --- |
| API endpoint | `https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic` |
| `haiku` | `qwen3.6-flash` |
| `sonnet` | `qwen3.8-flash` |
| `opus` | `qwen3.8-max` |
| `ANTHROPIC_MODEL` / subagent model | `auto` |
| Max context tokens | `983616` |
| API timeout | `3000000` milliseconds |
| Nonessential Claude Code traffic | Disabled |
| Inherited `CLAUDECODE` | Removed before invocation |

This matches Model Studio's Claude Code guide for the Token Plan Personal
Edition. The endpoint serves Anthropic-compatible `/v1/messages` only.

These environment variables change the defaults:

| Variable | Effect |
| --- | --- |
| `QWEN_BASE_URL` | Overrides the API endpoint |
| `QWEN_HAIKU_MODEL`, `QWEN_SONNET_MODEL`, `QWEN_OPUS_MODEL` | Override the model that each logical alias maps to |
| `CLAUDE_MODEL` | Sets the default logical alias for `run`, `start`, and `tui`; the default is `sonnet` |
| `QWEN_AGENT_HOME` | Changes the state directory, which is useful for isolated tests |
| `QWEN_SYSTEM_PROMPT_FILE` | Names the system prompt Markdown file; the default is `core/system-prompt.md` in the checkout |
| `QWEN_ROLE_PROMPTS_DIR` | Names the directory with `explorer.md` and `general-purpose.md`; the default is `core/prompts/` |
| `QWEN_WORKER_RETENTION_DAYS` | Sets how many days a finished worker is kept after its last activity; the default is `21`, and `0` turns the cleanup off |
| `QWEN_DISPATCH_CLI` | Replaces the CLI path in `qwen-dispatch`; it exists for the tests |

## Quota

Alibaba Cloud Model Studio exposes no key-based usage endpoint for the Token
Plan: the plan key is inference-only, and usage queries need a console
session or Alibaba Cloud AccessKeys. `qwen-agent` therefore ships without a
`quota` command, and `qwen-dispatch` never blocks on quota — its `scope` and
`quota_*` receipt fields always print `unknown`. If Model Studio documents a
key-based endpoint later, add it as a `PROF_QUOTA_BACKEND` in
`core/providers/qwen.sh`; the dispatch gate already switches on that hook.

## Quick start

`start` creates a worker and runs its first turn. Run it for a target
repository:

```bash
qwen-agent start --role general-purpose --model sonnet --cwd /path/to/project \
  "Implement the requested change and run the relevant tests."
```

A successful turn prints control fields in this shape:

```text
WORKER_ID=20260928T032843Z-15896-30630
TURN=1
MODEL=sonnet
ROLE=general-purpose
STATUS=DONE
RESULT=/Users/example/.qwen/workers/20260928T032843Z-15896-30630/turns/0001/result.md
ERROR_KIND=
PROVIDER_CODE=
FALLBACK_RECOMMENDED=false
```

| Field | Value |
| --- | --- |
| `WORKER_ID` | The worker ID that later commands take |
| `TURN` | The turn number |
| `MODEL` | `opus`, `sonnet`, or `haiku` |
| `ROLE` | `explorer` or `general-purpose` |
| `STATUS` | `DONE`, `BLOCKED`, `NO_REPORT`, or `INVALID` |
| `RESULT` | The absolute path of the result file |
| `ERROR_KIND` | The failure classification, or empty |
| `PROVIDER_CODE` | The Model Studio error code or error type, or empty |
| `REASON` | With `NO_REPORT` only: `result-file-missing` or `result-status-invalid` |
| `REPLY` | With `NO_REPORT` only: the absolute path of the worker's last reply, or empty |
| `NEXT` | With `NO_REPORT` only: `read-reply` when `REPLY` is set, otherwise `inspect-changes` |
| `FALLBACK_RECOMMENDED` | `true` or `false` |

`start` takes these options:

| Option | Values | Default |
| --- | --- | --- |
| `--role` | `explorer`, `general-purpose` | `general-purpose` |
| `--model` | `opus`, `sonnet`, `haiku` logical aliases | `sonnet` |
| `--cwd` | An existing directory | The current directory |

`send` always reuses the role, model, and directory that the worker stored at
creation.

Inspect the file that `RESULT` names and the actual repository changes. If the
worker needs a correction, resume the same Claude session:

```bash
qwen-agent send 20260928T032843Z-15896-30630 \
  "Fix the failing test, rerun the suite, and update the result."
```

When no more turns are needed, close the worker. Its history stays on disk:

```bash
qwen-agent close 20260928T032843Z-15896-30630
```

## Worker results

A worker reports through a result file, and the wrapper turns that file into
a `STATUS`.

| `STATUS` | Meaning |
| --- | --- |
| `DONE` | The worker produced a valid result that ends in `STATUS: DONE` |
| `BLOCKED` | The worker produced a valid result that ends in `STATUS: BLOCKED` |
| `NO_REPORT` | The turn ended without a valid result file. This is not an error. The work may be done, so read `REPLY` and check the changed files. Do not close the worker or resend the task |
| `INVALID` | Claude failed or returned malformed data |
| `RUNNING` | A turn is executing, or an external event interrupted it |
| `NEW` | The worker exists and no turn has begun |

Each worker turn receives an absolute `QWEN_RESULT_FILE` path and the contents
of `core/system-prompt.md`. The worker follows these steps:

1. Execute and verify the requested work.
2. Write the complete report to the result file.
3. Read the report back.
4. End the report with exactly one of these two lines:

   ```text
   STATUS: DONE
   STATUS: BLOCKED
   ```

- The system prompt asks for a report with the sections `# Summary`,
  `# Changes`, `# Verification`, and `# Remaining Issues`.
- Starting a background process is not completion.
- The wrapper classifies a failed Claude invocation and an invalid response as
  `INVALID`. It classifies a missing result and a malformed final status as
  `NO_REPORT`.
  - Raw output stays on disk for diagnosis.
- The wrapper reads the system prompt and the selected role prompt from disk at
  the start of every turn.
  - Set `QWEN_SYSTEM_PROMPT_FILE` or `QWEN_ROLE_PROMPTS_DIR` to use other
    readable, non-empty Markdown sources.

## Run workers asynchronously

`start --async` and `send --async` return a `RUNNING` receipt before the
provider finishes. Launch a worker without holding the bridge agent open:

```bash
qwen-agent start --async --role explorer --model haiku --cwd /path/to/project \
  "Trace the dependency path and write a verified report."
```

`STATUS=RUNNING` is a launch receipt, not task completion. Record the returned
`WORKER_ID`, then observe the worker with a bounded wait:

```bash
qwen-agent wait --timeout 20 <worker-id>
qwen-agent status <worker-id>
```

`--timeout` takes 0 to 300 seconds and defaults to 20. Resume the same session
asynchronously with:

```bash
qwen-agent send --async <worker-id> "Apply the review feedback and rerun tests."
```

Stop an active asynchronous turn explicitly:

```bash
qwen-agent cancel <worker-id>
```

Stopping the parent Claude Code turn does not cancel a detached Qwen worker.
The parent or a later bridge agent uses the recorded worker ID to wait,
inspect, continue, or cancel it. Cancellation signals the managed provider
process group, preserves partial artifacts, and records `INVALID/interrupted`.

## Open a plain Claude Code session

`qwen-agent tui` opens a plain interactive Model Studio-backed Claude Code
session. The session is your own main conversation:

```bash
qwen-agent tui --model sonnet --cwd /path/to/project
```

The command prints the allocated `SESSION_ID` before the session starts.
Reopen that exact session later with:

```bash
qwen-agent tui --resume <session-id>
```

| Property | Worker (`start`, `send`) | `tui` session |
| --- | --- | --- |
| Worker created | Yes | No |
| Worker contract system prompt | Injected | None |
| Result files | Written | None |
| Resume with | `send <worker-id> <message>` | `tui --resume <session-id>` |

## Dispatch

`qwen-dispatch` sends one task to a worker, waits, and prints one event line
per outcome. Call it with `run --wait` through Bash in the background; every
subcommand takes `--session <orchestrator-session-id>`, and all but `pending`
take `--label <name>`.

| Line | Meaning |
| --- | --- |
| `QWEN_RECEIPT label=<l> worker=<id> turn=<n> role=<r> model=<m> cwd=<dir> scope=unknown quota_5h_used=unknown quota_1w_used=unknown` | The worker started. This line is the proof that the task reached Qwen; the scope and quota fields are always `unknown` |
| `QWEN_VERDICT status=DONE` | The worker finished; read the result file and `files_changed` |
| `QWEN_VERDICT status=BLOCKED` | The worker declared itself blocked; read the result file |
| `QWEN_VERDICT status=NO_REPORT next=<read-reply or inspect-changes>` | The turn ended without a valid result file. Not an error: read the response or inspect the working tree |
| `QWEN_VERDICT status=INVALID class=<error-kind>` | An authentication, model, quota, protocol, or transient failure |
| `QWEN_STALLED label=<l> worker=<id> idle_seconds=<n>` | No progress signal for `--stall-timeout` seconds; `cancel` and retry once under a new label |
| `QWEN_STILL_RUNNING label=<l> worker=<id> waited_seconds=<n>` | `--max-wait` was reached; re-arm with `attach` or `cancel` |
| `QWEN_NOT_REACHED reason=<r>` | Receipt verification failed; retry once or go native |
| `QWEN_WARN explorer_modified files=<f>` or `QWEN_WARN out_of_scope files=<f>` | The worker changed files outside its contract; inspect and decide on rollback |

Subcommands: `run`, `send`, `attach`, `pending`, `ack`, `status`, `result`,
`cancel`, `close`. Exit codes: 0 success, 1 a `BLOCKED` or `INVALID` verdict
or a refused `ack`/`close`, 2 argument errors, 11 `QWEN_NOT_REACHED`,
12 `QWEN_STALLED`, 13 `QWEN_STILL_RUNNING`. The skill
`qwen-agent:dispatch` documents the full call and decision table.

## Choose a provider

The orchestrator chooses the provider before it delegates work. Prefer native
Claude for connector/MCP work, design or safety rulings, and changes to this
provider wrapper itself. A Qwen worker does not inherit the parent Claude Code
session's connectors, authentication, or MCP tools.

From the main session, `qwen-dispatch` (skill `qwen-agent:dispatch`) is the
recommended path to a Qwen worker. The bridge agents are not recommended.
A bridge agent can read the brief and answer it itself without calling Qwen.
A bridge report alone therefore does not prove that a Qwen worker ran.
The plugin keeps both bridge agents. Use one only when Bash cannot run
`qwen-dispatch`.

- Automatic native fallback is appropriate only when the control fields
  contain both `ERROR_KIND=quota-exhausted` and `FALLBACK_RECOMMENDED=true`.
- Temporary provider failures, authentication errors, unavailable models, and
  worker protocol errors stay visible to the orchestrator.

## Command reference

| Command | What it does |
| --- | --- |
| `api-key [key]` | Store a Model Studio API key, or prompt for it securely. While an account is active, it replaces that account's key. |
| `auth add personal --name <name> --api-key <key>` | Save a personal account without activating it. |
| `auth switch <name>` | Make an account active. |
| `auth remove <name>` | Delete an account that is not active. |
| `auth list` | List the accounts and mark the active one. |
| `run <prompt>` | Run a one-shot diagnostic session without creating a worker. |
| `start [--role <role>] [--model <alias>] [--cwd <dir>] <task>` | Create a persistent worker and execute turn 1. |
| `start --async ... <task>` | Create a worker and return its RUNNING receipt before provider completion. |
| `send <worker-id> <message>` | Resume the worker's original session, directory, role, and model. |
| `send --async <worker-id> <message>` | Resume the same session in a detached turn. |
| `wait [--timeout <seconds>] <worker-id>` | Wait up to 0–300 seconds for terminal state; the default is 20. |
| `cancel <worker-id>` | Interrupt an active asynchronous headless turn. |
| `tui [--model <alias>] [--cwd <dir>] [--resume <id>]` | Open a plain interactive Claude Code session (no worker). |
| `result <worker-id>` | Print the latest valid durable result path. |
| `status <worker-id>` | Print compact worker state without exposing the session ID. |
| `list` | List known workers. |
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `--help` | Show the complete CLI and worker contract. |
| `--version` | Print the wrapper version. |

| Exit status | Meaning |
| --- | --- |
| 0 | The command succeeded. `DONE`, `BLOCKED`, and `NO_REPORT` are all successful turns |
| 1 | The Claude invocation or the worker response failed (`STATUS=INVALID`) |
| 2 | Invalid CLI usage, configuration, dependency, or worker state |

## Worker state

Worker history lives under `~/.qwen/workers/<worker-id>/`:

```text
meta
task.md
turns/
  0001/
    mode
    prompt.md
    response.json
    stderr.log
    result.md
  0002/
    ...
```

- The wrapper stores the selected role and the latest provider classification
  in `meta`.
- Raw response and stderr stay on disk. Compact stdout carries no Claude
  session ID.
- Asynchronous headless turns also contain `runner.log`.
- `close` only marks a worker closed. The directory and all turn data stay.
- `start` deletes a worker that has finished (`DONE`, `BLOCKED`, `NO_REPORT`,
  or `INVALID`) and has seen no activity for `QWEN_WORKER_RETENTION_DAYS`
  days. It checks at most once per 24 hours, whether or not the worker is
  closed.
  - A `RUNNING` or `NEW` worker, a directory without `meta`, and a locked
    worker stay.
  - Each deletion is logged in `~/.qwen/cleanup.log`. The cleanup never
    changes the output of `start`.

## Security

`start` and `send` invoke Claude Code with `--dangerously-skip-permissions`.
A headless worker needs this mode to edit files and run verification without
an interactive approval prompt. `tui` passes the same flag. Start workers
only in repositories you trust.

- Both roles run in this mode. The `explorer` read-only limit is a behavioral
  prompt contract, and the permission mode allows edits. The parent
  orchestrator must verify the working tree for unexpected changes.
- The wrapper never prints the API key, and `status` does not expose the
  Claude session ID.
- `~/.qwen` and each `~/.qwen/accounts/<name>/` have mode `0700`. The key
  file inside an account has mode `0600`. `~/.qwen/.env.auth` is a symlink
  to the active account.
- `auth add --api-key "<key>"` puts the key in the process argument list. Use
  `--api-key -` to read it from stdin.
- Keep `~/.qwen`, captured worker files, and shell output that may contain
  private task data out of commits.

## License

[MIT](../LICENSE) © 2026 Heejoon Kang
