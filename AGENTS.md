# AGENTS.md — provider-agent development guide

This file is the canonical repository instruction source. `CLAUDE.md` is a
symlink to `AGENTS.md` for Claude Code compatibility. Edit only `AGENTS.md`;
the symlink reflects changes automatically.

## Project scope

`provider-agent` is a monorepo of Bash CLIs and Claude Code plugins that run
persistent coding workers through Claude Code against Anthropic-compatible
provider endpoints. One shared engine in `core/` implements the worker model;
each provider contributes a profile and a thin plugin directory. Version 1
deliberately remains a local CLI and filesystem protocol. Do not introduce
MCP, a daemon, a database, or another implementation language without an
explicit design decision.

Keep stdout compact and control-plane oriented. Detailed worker reports, raw
Claude JSON, and stderr belong under the worker directory.

The shipped providers are `glm` (Z.ai GLM) and `qwen` (Alibaba Cloud Model
Studio Qwen, Token Plan). Adding a provider means adding a profile and a
plugin directory; engine changes must stay provider-neutral or go through
the documented hooks.

## Repository layout

- `core/agent-core.sh`: shared CLI engine and embedded user-facing help.
  Sourced by each provider entry after the provider profile.
- `core/providers/*.sh`: provider profiles. Each defines the `PROF_*`
  variables documented at the top of `agent-core.sh` and may override the
  provider hooks (`extract_provider_code`, `classify_error_kind`,
  `provider_response_is_error`).
- `core/dispatch/dispatch-*.sh`: dispatch modules (arguments, quota gate,
  registry, run, wait, git snapshot, subcommands); each file is sourced,
  never run, and defines functions and shared text. Event line prefixes come
  from the `DD_EVT_*` variables an entry sets.
- `core/system-prompt.md`: worker execution and durable-result contract,
  loaded directly at the start of every worker turn.
- `core/prompts/`: role-specific worker prompts, loaded directly on every
  turn.
- `glm/`, `qwen/`: plugin directories. Each holds the provider entry script
  (`<id>-agent`), `scripts/<id>-dispatch`, bridge agents, skills, a
  `README.md`, and `.claude-plugin/plugin.json`.
- `.claude-plugin/marketplace.json`: marketplace manifest listing both
  plugins with their `source` directories.
- `scripts/bump-version.sh`: synchronized version bump per plugin across the
  profile, plugin manifest, and marketplace entry.
- `tests/test_glm_agent.sh`: hermetic CLI tests for the glm profile using
  fake `claude` and `curl` binaries.
- `tests/test_qwen_agent.sh`: hermetic CLI tests for the qwen profile.
- `tests/test_plugin.sh`: plugin schema, bridge contract, skill contract,
  and version parity tests for both plugins.
- `tests/test_dispatch.sh`: runs every `tests/dispatch/test_*.sh` and sums
  the TAP counts.
- `tests/dispatch/`: dispatch tests, the shared harness `lib.sh` (fake
  `claude`, `curl`, and CLI), and `quota-rows.tsv`.
- `README.md`: monorepo overview. `glm/README.md` and `qwen/README.md` are
  the per-provider public documentation.
- `LICENSE`: MIT License terms for the project.
- `CLAUDE.md`: compatibility symlink; never replace it with an independent
  copy.

## Provider profile contract

The entry script sources `core/providers/<id>.sh` before `agent-core.sh`.
Required scalars: `PROF_ID`, `PROF_LABEL`, `PROF_PROVIDER_NAME`,
`PROF_VERSION`, `PROF_HOME_DIR`, `PROF_DEFAULT_BASE_URL`,
`PROF_DEFAULT_HAIKU_MODEL`, `PROF_DEFAULT_SONNET_MODEL`,
`PROF_DEFAULT_OPUS_MODEL`, and `PROF_ENV_*` names for `AGENT_HOME`,
`API_KEY`, `BASE_URL`, `HAIKU_MODEL`, `SONNET_MODEL`, `OPUS_MODEL`,
`SYSTEM_PROMPT_FILE`, `ROLE_PROMPTS_DIR`, `ROLE`, `RESULT_FILE`,
`RETENTION_DAYS`, `DISPATCH_CLI`, plus optional `PROF_ENV_QUOTA_ORGANIZATION`
and `PROF_ENV_QUOTA_PROJECT`. Optional: `PROF_QUOTA_BACKEND` (`monitor` or
`none`), `PROF_SUPPORTS_TEAM_SCOPE`, `PROF_CLAUDE_ENV_EXTRA` (array),
`PROF_ENTRY_PATH`.

- The engine reads user configuration only through the `PROF_ENV_*` names by
  indirect expansion. Never hardcode a provider variable name in `core/`.
- User-facing environment variable names are part of the public contract:
  glm keeps `GLM_*` and `ZAI_*` names; qwen uses `QWEN_*` names. Do not
  rename them.
- The qwen provider has no quota backend (`none`): Model Studio exposes no
  key-based Token Plan usage endpoint. The dispatch gate fails open and the
  `quota` command exits 2. Revisit only if Alibaba documents a key-based
  endpoint.

## Behavioral invariants

Preserve these unless the requested change explicitly revises the contract:

- `start` creates a worker and captures its Claude session ID.
- `send` resumes that exact session and reuses the original working directory
  and model.
- Each turn has `prompt.md`, `response.json`, `stderr.log`, and `result.md`.
- The profile's `PROF_ENV_RESULT_FILE` variable carries an absolute path to
  the turn's canonical durable report into the worker environment.
- A valid report ends with exactly `STATUS: DONE` or `STATUS: BLOCKED`.
- Invocation failures and malformed provider data become `INVALID`. A turn
  that ends without a valid result file becomes `NO_REPORT`.
- Starting a background process alone is not completion.
- `close` preserves worker history and rejects later `send` calls.
- API keys and Claude session IDs must not appear in normal stdout.
- For providers with a quota backend, `quota` passes the API key to `curl`
  only as a stdin header (`-H @-`); it never appears in argv, stdout, stderr,
  or files. Team-scope selectors share that stdin header block.
- Credentials live in named accounts under `~/<PROF_HOME_DIR>/accounts/<name>/`:
  `api-key`, plus `team-scope` for a team account when the provider supports
  one (directory mode 0700, files mode 0600). `~/.<PROF_HOME_DIR>/.env.auth`
  is a relative symlink to the active account's `api-key`. The active account
  name is the `.env.auth` link target; no other file stores it.
- Only `auth` subcommands migrate a legacy regular `.env.auth` into an
  account, and `auth add` never changes the active account. Team accounts
  are rejected for providers with `PROF_SUPPORTS_TEAM_SCOPE` false.
- `core/system-prompt.md` is read directly on every turn; it is not
  duplicated in the Bash source.
- Detached turns re-invoke the provider entry (`PROF_ENTRY_PATH`), never the
  bare core: the core without a profile aborts by design.

## Verified provider configurations

glm (Z.ai):

```text
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3-flash[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3[1m]
CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
API_TIMEOUT_MS=3000000
```

qwen (Alibaba Cloud Model Studio, Token Plan Personal):

```text
ANTHROPIC_BASE_URL=https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic
ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.6-flash
ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max
ANTHROPIC_MODEL=auto
CLAUDE_CODE_SUBAGENT_MODEL=auto
CLAUDE_CODE_MAX_CONTEXT_TOKENS=983616
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
API_TIMEOUT_MS=3000000
```

Unset inherited `CLAUDECODE` before invoking Claude. The default Claude alias
is `sonnet`. Authentication is stored in the active account and the key must
never be logged. The stored file is the only key source; the provider's
`PROF_ENV_API_KEY` environment variable is never read and is stripped from
the Claude process environment.

## Implementation rules

- Maintain compatibility with the Bash version shipped by macOS unless the
  documented minimum changes deliberately.
- Quote expansions and validate any value used in paths or metadata.
- Keep shared turn execution in `run_turn()`; do not duplicate it between
  `start` and `send`.
- Empty-array expansions under `set -u` must use the
  `${arr[@]+"${arr[@]}"}` idiom for Bash 3.2.
- Make state transitions explicit and retain raw failure artifacts.
- Treat worker directories as untrusted input when accepting a worker ID.
- Keep `--help`, the provider READMEs, tests, and implementation behavior
  synchronized.
- Prefer focused changes. Preserve unrelated user changes in a dirty
  worktree.

## Testing

For behavior changes, add or update a failing test before changing the
implementation. The fake Claude executable must not make network requests or
use a real API key.

Run before declaring work complete:

```bash
bash tests/test_glm_agent.sh
bash tests/test_qwen_agent.sh
bash tests/test_plugin.sh
bash tests/test_dispatch.sh
bash -n core/agent-core.sh core/providers/*.sh core/dispatch/*.sh glm/glm-agent glm/scripts/glm-dispatch qwen/qwen-agent qwen/scripts/qwen-dispatch scripts/bump-version.sh tests/*.sh tests/dispatch/*.sh
shellcheck --external-sources --source-path=SCRIPTDIR core/agent-core.sh core/providers/*.sh core/dispatch/*.sh glm/glm-agent glm/scripts/glm-dispatch qwen/qwen-agent qwen/scripts/qwen-dispatch scripts/bump-version.sh tests/*.sh tests/dispatch/*.sh
claude plugin validate --strict ./glm
claude plugin validate --strict ./qwen
```

If `shellcheck` is unavailable, report that fact rather than silently
skipping the check. For changes to live provider integration, run a narrowly
scoped real smoke test only when credentials and authorization are already
available, and never print or inspect the key itself.

For releases, run `scripts/bump-version.sh <plugin> <major.minor.patch>`
rather than editing version fields individually. The profile, plugin
manifest, and marketplace entry of that plugin must remain identical and the
parity tests must pass. The bump script does not commit, tag, or push.

Also inspect the final diff and confirm that documentation examples match the
current command output and exit-status behavior.

## Documentation and prompt changes

`core/system-prompt.md` is runtime behavior, not ordinary prose. Changes can
alter what every worker does, so cover its required clauses with tests and
review it like code.

Edit agent instructions only in `AGENTS.md`. Keep `CLAUDE.md` as a relative
symlink to `AGENTS.md` so clones remain portable.
