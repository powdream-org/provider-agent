---
name: dispatch
description: Use when sending a task to a Qwen worker, handing a follow-up to the same worker, or collecting its result, after the provider is already chosen as Qwen.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-dispatch" *)
---

# Qwen dispatch

`qwen-dispatch` is a script that sends one task to a Qwen worker, waits for it, and prints a verdict line.
One call starts the worker, verifies the receipt, waits, and reports.
The `QWEN_RECEIPT` line it prints is the proof that the worker started.

## When to use

Use this skill after the provider is chosen as Qwen. Provider selection happens before it.

- Run `qwen-dispatch` instead of the `qwen-agent:*` bridge agents.
- Use a bridge agent as the fallback when Bash cannot run the script.
- "Native" below means Claude does the task instead of a Qwen worker.

Every subcommand runs as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-dispatch" <subcommand> ...`.
Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_SESSION_ID}` in this skill before you read it.

## Prepare

The call needs these inputs.

| Input | Rule |
| --- | --- |
| Brief file | The worker's instructions. The caller writes it. It must be readable, non-empty, and at most 262144 bytes |
| Label | A task name, unique within the session. 1 to 64 characters: letters, digits, `.`, `_`, `-`, starting with a letter or digit |
| Role | `explorer` for read-only investigation, `general-purpose` for implementation |
| Model | `haiku`, `sonnet`, or `opus` |
| Cwd | An existing directory where the worker runs |

- The script passes the whole brief file, line breaks included, as one argument.
  - A brief that starts with `-` works like any other brief.
  - A file over 262144 bytes exits 2 with `qwen-dispatch: task-file too large (max 262144 bytes)`.
  - That size check runs before the worker starts.
- A repeated label exits 2 with `qwen-dispatch: label already exists`.
- The `explorer` read-only limit is an instruction in the worker's prompt. The script reports violations with `QWEN_WARN explorer_modified`.
- `run` takes `--role`, `--model`, and `--cwd` as required flags with no defaults.
  - A missing flag exits 2 with `qwen-dispatch: --role is required`. `--model` and `--cwd` use the same form.
  - The role is explicit because the `explorer` limit is only a prompt instruction.

## Run

Start `run` with `--wait` in the background.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-dispatch" run --label <label> --role <role> --model <model> --cwd <dir> --task-file <brief> --session ${CLAUDE_SESSION_ID} --wait
```

- Set the Bash tool to `run_in_background: true` and `timeout: 7200000`.
  - `timeout: 7200000` is the 2-hour Bash maximum. The default is 30 minutes.
  - Measured worker runs took 4.5 to 33 minutes.
- Claude Code notifies you when the command ends. Read the output then.
- The wait always ends: at the worker's end, at `--max-wait`, or at a stall.
- Keep `--max-wait` under 7200 so the script ends before the Bash timeout.
- When the expected duration exceeds 10 minutes, also set a one-shot `CronCreate` timer as a backstop.
  - The timer is a channel separate from the notification.
  - Set it to fire after the expected duration.
  - When it fires before the notification, run `pending`.
- A `run` without `--wait` prints `QWEN_RECEIPT` and exits 0. Check it later with `pending`.
- The worker keeps running if the background command dies, because the script starts it detached. Re-arm the wait with `attach`.

Optional flags:

| Flag | Default | Effect |
| --- | --- | --- |
| `--max-wait <s>` | 7000 | Wait ceiling in seconds. At the ceiling the script prints `QWEN_STILL_RUNNING`; the worker keeps running |
| `--stall-timeout <s>` | 300 | Seconds without a progress signal before `QWEN_STALLED`. 0 turns detection off |
| `--poll-seconds <s>` | 20 | Seconds between the script's internal status checks |
| `--allow-path <glob>` | none | Repo-relative path pattern for expected changes. Repeatable |

Numeric flags take positive integers.

## Read the output

Each event is one stdout line with space-free values. Read every `QWEN_` line, then act on it.

| Line | Meaning | Next action |
| --- | --- | --- |
| `QWEN_NOT_REACHED reason=<reason>` | The receipt check failed | Log that Qwen was not reached. Read `reason`, then retry once or go native |
| `QWEN_RECEIPT label=<l> worker=<id> turn=<n> role=<r> model=<m> cwd=<dir> scope=unknown quota_5h_used=unknown quota_1w_used=unknown` | The worker started. Its `meta` exists, role, model, and cwd match, and `STATUS=RUNNING`. Alibaba Cloud Model Studio has no key-based quota endpoint, so the scope and quota fields are always `unknown` | Quote the line verbatim in the work log |
| `QWEN_VERDICT ... status=DONE` | The worker finished | Read the result file and check `files_changed` |
| `QWEN_VERDICT ... status=BLOCKED` | The worker declared itself blocked | Read the result file and judge |
| `QWEN_VERDICT ... status=NO_REPORT class=- ... next=<read-reply or inspect-changes>` | The turn ended without a valid result file. This is not an error. The work may be done | Do not close the worker and do not resend the task. When `next=read-reply`, read the `--- Response ---` section and judge from it. When `next=inspect-changes`, check `files_changed` and the working tree yourself. If more is needed, `send` one line to the same worker. The worker may have worked outside `cwd`, in another repository for example |
| `QWEN_VERDICT ... status=INVALID class=quota-exhausted` | Model Studio reported the plan quota as exhausted (`fallback=true`) | Turn Qwen off until the plan resets. Native takes over. The worktree changes remain |
| `QWEN_VERDICT ... status=INVALID class=worker-protocol` | The response was malformed or its session did not match | The state of the work is unknown. Check `files_changed` and the working tree, log the class, and ask the user before you retry |
| `QWEN_VERDICT ... status=INVALID class=<any other>` | Authentication, model, or transient failure | Log the class and ask the user |
| `QWEN_STALLED label=<l> worker=<id> idle_seconds=<n>` | No progress signal for `--stall-timeout` seconds | `cancel`, then start again once with the same `--model` under a new label. If it stalls again, report a fault to the user |
| `QWEN_STILL_RUNNING label=<l> worker=<id> waited_seconds=<n>` | `--max-wait` was reached and the worker keeps running | Wait again with `attach`, or `cancel` |
| `QWEN_WARN explorer_modified files=<list>` | An `explorer` worker changed files | Inspect the listed files. Decide on rollback yourself |
| `QWEN_WARN out_of_scope files=<list>` | A changed file matches no `--allow-path` pattern | Inspect the listed files. Decide on rollback yourself |

`QWEN_NOT_REACHED` carries one of these reasons: `cli-failed`, `receipt-incomplete`, `meta-missing`, `meta-mismatch`, `not-running`.
A `QWEN_NOT_REACHED` run leaves the registry unchanged.

- `QWEN_WARN` prints right before `QWEN_VERDICT` and leaves the exit code unchanged.
- `QWEN_VERDICT` carries `status`, `class`, `result`, `files_changed`, `quota_1w_delta`, and `fallback`.
  - `class` is the worker's `ERROR_KIND`, or `-` when empty.
  - `result` is the absolute path of the result file, or `-`.
  - `files_changed` counts files changed since the start. It is `na` outside a git repository.
  - `quota_1w_delta` is always `unknown` for this provider.
- `--- Summary ---` and `--- Remaining Issues ---` blocks follow `QWEN_VERDICT`.
  - Each block holds the result file's section, cut to 20 lines with a closing `... (truncated)`.
  - Both blocks are omitted when no result file exists.
  - A `NO_REPORT` turn without a result file prints a `--- Response ---` block right after `QWEN_VERDICT` instead.
  - That block holds the first 20 lines of the worker's reply, closed by `... (truncated)` when the reply is longer.
  - It prints only when the turn reported no error and the reply is non-empty. `DONE`, `BLOCKED`, and `INVALID` never print it.
- A turn can end `NO_REPORT` after the work is finished. Read the Response section and `files_changed` before you call it a failure. `NO_REPORT` is not a failure.
- `QWEN_STALLED` needs the worker's CPU time to be readable. When it cannot be read, the wait runs until `--max-wait` and ends with `QWEN_STILL_RUNNING`.
- In `QWEN_RECEIPT` and in the registry, each space in `cwd` is written as `%20`.

Exit codes:

| Code | Event |
| --- | --- |
| 0 | `QWEN_VERDICT status=DONE` or `status=NO_REPORT`; a `run` or `send` without `--wait` that printed `QWEN_RECEIPT`; `pending` |
| 1 | `QWEN_VERDICT` with `BLOCKED` or `INVALID`; a refused `ack` or `close` |
| 2 | Argument check failure or usage error: one stderr line `qwen-dispatch: <reason>`, no stdout |
| 11 | `QWEN_NOT_REACHED` |
| 12 | `QWEN_STALLED` |
| 13 | `QWEN_STILL_RUNNING` |

## Follow up

Every subcommand takes `--session ${CLAUDE_SESSION_ID}`. All but `pending` also take `--label <label>`.

| Subcommand | Use | Prints |
| --- | --- | --- |
| `send` | Hand a follow-up to the same worker. Needs `--task-file`; takes `--wait`, `--max-wait`, `--stall-timeout`, `--poll-seconds`, `--allow-path` | A new `QWEN_RECEIPT`, or `QWEN_NOT_REACHED`. A label that does not exist exits 2 |
| `attach` | Re-arm the wait on a worker. Always waits; takes `--max-wait`, `--stall-timeout`, `--poll-seconds` | The same lines as `run --wait` |
| `pending` | List tasks that are running or finished but not acknowledged | `QWEN_PENDING label=<l> worker=<id> state=<running or terminal-unacked> status=<STATUS>`, or `QWEN_PENDING none` |
| `ack` | Mark a finished task as read | `QWEN_ACK label=<l>`. A running worker gets `QWEN_ACK_REFUSED label=<l> reason=running` and exit 1 |
| `status`, `result` | Read the worker's status or result | `LABEL=<label>`, then the CLI output. The exit code is the CLI's |
| `cancel` | Stop a running worker | `LABEL=<label>`, then the CLI output. The exit code is the CLI's |
| `close` | Close a finished worker | A running worker gets `QWEN_CLOSE_REFUSED label=<l> reason=running` and exit 1. `cancel` it first |

- Start `send --wait` and `attach` with the same Bash settings as `run --wait`. The other subcommands finish quickly; run them in the foreground.
- Run `ack` after you act on a verdict, so `pending` stops listing the task.

## Record

Log every dispatch in the work log (the ledger).

| Event | What you write |
| --- | --- |
| `QWEN_RECEIPT` printed | The `QWEN_RECEIPT` line, quoted verbatim |
| `QWEN_NOT_REACHED` printed | That the task did not reach Qwen. Record the native result as native, not as a Qwen result |
| A bridge agent ran the task | The result as Qwen work only if the report carries `WORKER_ID`, `TURN`, and `STATUS` receipt fields |

## Do not

- Do not retype the brief into the command. Pass the file with `--task-file`.
- Do not wait with `sleep`, `while` or `until` loops, or file watching. Use `--wait` or `pending`.
- Do not open or print `~/.qwen/.env.auth` or anything under `~/.qwen/accounts/`. Only the CLI reads them.
- Do not record a worker result as Qwen work without its `QWEN_RECEIPT` line. Quote the line next to the result.
- Do not `close` a running worker. `cancel` it first.
