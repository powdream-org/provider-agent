#!/usr/bin/env bash
# Hermetic tests for the qwen provider profile. The shared engine behavior is
# covered by tests/test_glm_agent.sh; this suite verifies the Qwen-specific
# configuration, environment contract, classification hooks, and a smoke
# worker flow, all through fake binaries and no network.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
SCRIPT="$REPO_DIR/qwen/qwen-agent"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TEMP_BASE/qwen-agent-test.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
PROJECT="$TEST_ROOT/project"
OTHER_PROJECT="$TEST_ROOT/other-project"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/claude.log"
QWEN_AGENT_HOME="$TEST_HOME/.qwen"
export QWEN_AGENT_HOME
export FAKE_LOG

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

tests=0
failures=0

pass() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1"
  printf '  %s\n' "$2"
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected [$2], got [$3]"
  fi
}

assert_contains() {
  if [[ "$2" == *"$3"* ]]; then
    pass "$1"
  else
    fail "$1" "missing [$3] in [$2]"
  fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    pass "$1"
  else
    fail "$1" "unexpected [$3] present in [$2]"
  fi
}

capture() {
  local stderr_file="$TEST_ROOT/captured.stderr"
  : >"$stderr_file"
  if OUTPUT="$("$@" 2>"$stderr_file")"; then
    RC=0
  else
    RC=$?
  fi
  STDERR="$(cat "$stderr_file")"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

mkdir -p "$FAKE_BIN" "$TEST_HOME" "$PROJECT" "$OTHER_PROJECT"
git -C "$PROJECT" init -q 2>/dev/null || true

# The fake claude logs the provider env it received, then behaves as the
# worker contract requires: it writes the result file when the engine injects
# QWEN_RESULT_FILE, and answers run-mode calls with a plain line.
cat >"$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
{
  printf 'base_url=%s\n' "${ANTHROPIC_BASE_URL:-unset}"
  printf 'token_present=%s\n' "$([[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && printf yes || printf no)"
  printf 'haiku=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-unset}"
  printf 'sonnet=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-unset}"
  printf 'opus=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-unset}"
  printf 'model=%s\n' "${ANTHROPIC_MODEL:-unset}"
  printf 'subagent=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL:-unset}"
  printf 'max_context=%s\n' "${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-unset}"
  printf 'compact=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-unset}"
  printf 'qwen_result_file_set=%s\n' "$([[ -n "${QWEN_RESULT_FILE:-}" ]] && printf yes || printf no)"
  printf 'result_file=%s\n' "${QWEN_RESULT_FILE:-NEVER_SET}"
  printf 'qwen_api_key_present=%s\n' "$([[ -n "${QWEN_API_KEY:-}" ]] && printf yes || printf no)"
  printf 'claudecode=%s\n' "${CLAUDECODE:-unset}"
  printf 'args=%s\n' "$*"
} >>"${FAKE_LOG:?}"

if [[ "${QWEN_FAKE_MODE:-}" == error ]]; then
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"qwen-session-1","error":{"type":"%s"},"result":"%s"}\n' \
    "${QWEN_FAKE_ERROR_TYPE:-insufficient_quota}" \
    "${QWEN_FAKE_ERROR_TEXT:-plan quota exhausted}"
  exit 1
fi

if [[ -n "${QWEN_RESULT_FILE:-}" ]]; then
  printf '# Summary\nCompleted by fake worker\n\n# Changes\nnone\n\n# Verification\nfake\n\n# Remaining Issues\nnone\n\nSTATUS: DONE\n' \
    >"$QWEN_RESULT_FILE"
  printf '{"type":"result","subtype":"success","is_error":false,"session_id":"qwen-session-1","result":"ok"}\n'
else
  printf 'RUN_OK\n'
fi
FAKE
chmod +x "$FAKE_BIN/claude"

run_cli() {
  # The harness machine may carry provider environment from another agent;
  # the qwen contract must hold on a clean environment.
  PATH="$FAKE_BIN:$PATH" capture env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    -u CLAUDE_CODE_MAX_CONTEXT_TOKENS -u ANTHROPIC_MODEL \
    -u CLAUDE_CODE_SUBAGENT_MODEL "$SCRIPT" "$@"
}

# --- version and help -------------------------------------------------------

run_cli --version
assert_eq 'version reports the qwen plugin version' 'qwen-agent 0.1.0' "$OUTPUT"

run_cli --help
assert_contains 'help names the provider' "$OUTPUT" \
  'qwen-agent - persistent Qwen coding worker'
assert_contains 'help names Alibaba Cloud Model Studio' "$OUTPUT" \
  "Alibaba Cloud Model Studio's"
assert_contains 'help documents the result file variable' "$OUTPUT" \
  'QWEN_RESULT_FILE'
assert_contains 'help documents the retention variable' "$OUTPUT" \
  'QWEN_WORKER_RETENTION_DAYS'
assert_contains 'help documents api-key' "$OUTPUT" 'qwen-agent api-key [key]'
assert_not_contains 'help omits the quota command' "$OUTPUT" $'\n  qwen-agent quota\n'
assert_not_contains 'help omits team-scope' "$OUTPUT" 'team-scope'
assert_not_contains 'help omits team accounts' "$OUTPUT" 'auth add team'
assert_not_contains 'help omits the Token Plan endpoint from quota text' \
  "$OUTPUT" 'monitor API'

# --- provider commands that do not exist ------------------------------------

run_cli quota
assert_eq 'quota exits 2 for qwen' '2' "$RC"
assert_contains 'quota reports unavailability' "$STDERR" \
  'quota is not available for this provider'

run_cli team-scope
assert_eq 'team-scope exits 2 for qwen' '2' "$RC"

# --- auth accounts ----------------------------------------------------------

secret='qwen-test-secret-value'
run_cli auth add personal --name me --api-key "$secret"
assert_eq 'auth add succeeds' '0' "$RC"
assert_contains 'auth add receipt' "$OUTPUT" 'ACCOUNT=ADDED'
assert_not_contains 'auth add hides the key' "$OUTPUT" "$secret"
assert_eq 'account directory is private' '700' "$(file_mode "$QWEN_AGENT_HOME/accounts/me")"
assert_eq 'key file is private' '600' "$(file_mode "$QWEN_AGENT_HOME/accounts/me/api-key")"
[[ -f "$QWEN_AGENT_HOME/accounts/me/api-key" ]]
assert_eq 'stored key matches' "$secret" "$(cat "$QWEN_AGENT_HOME/accounts/me/api-key")"

run_cli auth add personal --name me --api-key other
assert_eq 'duplicate account name is an error' '2' "$RC"

run_cli auth add team --name corp --api-key x --organization o --project p
assert_eq 'team accounts are rejected for qwen' '2' "$RC"
assert_contains 'team rejection explains why' "$STDERR" \
  'team accounts are not available for this provider'

run_cli auth list
assert_contains 'auth list shows the account' "$OUTPUT" 'ACCOUNT_1_NAME=me'
assert_contains 'auth list marks it inactive' "$OUTPUT" 'ACCOUNT_1_ACTIVE=false'
assert_not_contains 'auth list hides keys' "$OUTPUT" "$secret"

run_cli auth switch me
assert_eq 'auth switch succeeds' '0' "$RC"
assert_contains 'switch receipt' "$OUTPUT" 'ACCOUNT=ACTIVE'
[[ -L "$QWEN_AGENT_HOME/.env.auth" ]]
assert_eq '.env.auth links to the active account' \
  'accounts/me/api-key' "$(readlink "$QWEN_AGENT_HOME/.env.auth")"

run_cli auth remove me
assert_eq 'removing the active account is refused' '2' "$RC"

# --- the worker environment contract ----------------------------------------

: >"$FAKE_LOG"
run_cli run "diagnostic prompt"
assert_eq 'diagnostic run succeeds' '0' "$RC"
assert_contains 'run returns the provider reply' 'RUN_OK' "$OUTPUT"
run_log="$(cat "$FAKE_LOG")"
assert_contains 'run uses the Token Plan endpoint' "$run_log" \
  'base_url=https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic'
assert_contains 'run maps haiku to qwen3.6-flash' "$run_log" 'haiku=qwen3.6-flash'
assert_contains 'run maps sonnet to qwen3.8-flash' "$run_log" 'sonnet=qwen3.8-flash'
assert_contains 'run maps opus to qwen3.8-max' "$run_log" 'opus=qwen3.8-max'
assert_contains 'run sets the main model to auto' "$run_log" 'model=auto'
assert_contains 'run sets the subagent model to auto' "$run_log" 'subagent=auto'
assert_contains 'run sets the max context window' "$run_log" 'max_context=983616'
assert_not_contains 'run sets no auto-compact window' "$run_log" 'compact=1000000'
assert_contains 'run strips the plan key from the environment' "$run_log" \
  'qwen_api_key_present=no'
assert_contains 'run strips the result file variable' "$run_log" \
  'qwen_result_file_set=no'
assert_contains 'run unsets nested Claude marker' "$run_log" 'claudecode=unset'

: >"$FAKE_LOG"
run_cli start --role general-purpose --model sonnet --cwd "$PROJECT" \
  "Implement the fake change."
assert_eq 'start succeeds' '0' "$RC"
worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
[[ -n "$worker_id" ]]
assert_contains 'start reports DONE' "$OUTPUT" 'STATUS=DONE'
assert_contains 'start reports the model alias' "$OUTPUT" 'MODEL=sonnet'
start_log="$(cat "$FAKE_LOG")"
assert_contains 'start injects QWEN_RESULT_FILE' "$start_log" 'qwen_result_file_set=yes'
assert_contains 'start names the variable for the worker' "$start_log" \
  'result_file='"$QWEN_AGENT_HOME"'/workers/'
assert_contains 'start passes the auth token' "$start_log" 'token_present=yes'
result_path="$(printf '%s\n' "$OUTPUT" | sed -n 's/^RESULT=//p')"
[[ -f "$result_path" ]]
assert_contains 'result ends with STATUS DONE' "$(cat "$result_path")" 'STATUS: DONE'
[[ -f "$QWEN_AGENT_HOME/workers/$worker_id/turns/0001/response.json" ]]
[[ -f "$QWEN_AGENT_HOME/workers/$worker_id/turns/0001/stderr.log" ]]
[[ -f "$QWEN_AGENT_HOME/workers/$worker_id/turns/0001/prompt.md" ]]
assert_contains 'worker system prompt names the qwen variable' \
  "$start_log" 'QWEN_RESULT_FILE is exactly this absolute path:'

: >"$FAKE_LOG"
run_cli send "$worker_id" "Apply a correction."
assert_eq 'send succeeds' '0' "$RC"
assert_contains 'send reports DONE' "$OUTPUT" 'STATUS=DONE'
send_log="$(cat "$FAKE_LOG")"
assert_contains 'send resumes the captured session' "$send_log" \
  '--resume qwen-session-1'

run_cli status "$worker_id"
assert_eq 'status succeeds' '0' "$RC"
assert_contains 'status reports the worker' "$OUTPUT" "WORKER_ID=$worker_id"
assert_not_contains 'status hides the session id' "$OUTPUT" 'qwen-session-1'

run_cli close "$worker_id"
assert_eq 'close succeeds' '0' "$RC"
run_cli send "$worker_id" "one more"
assert_eq 'closed worker rejects send' '2' "$RC"

# --- provider error classification ------------------------------------------

: >"$FAKE_LOG"
export QWEN_FAKE_MODE=error
export QWEN_FAKE_ERROR_TYPE=insufficient_quota
run_cli start --cwd "$PROJECT" "Trigger a quota error."
unset QWEN_FAKE_MODE QWEN_FAKE_ERROR_TYPE
assert_contains 'error turn reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'insufficient quota classifies as quota-exhausted' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
assert_contains 'quota exhaustion recommends fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=true'
assert_contains 'provider code carries the error type' "$OUTPUT" \
  'PROVIDER_CODE=insufficient_quota'

export QWEN_FAKE_MODE=error
export QWEN_FAKE_ERROR_TYPE=rate_limit_error
export QWEN_FAKE_ERROR_TEXT='request throttled'
run_cli start --cwd "$PROJECT" "Trigger a rate limit."
unset QWEN_FAKE_MODE QWEN_FAKE_ERROR_TYPE QWEN_FAKE_ERROR_TEXT
assert_contains 'rate limit stays transient' "$OUTPUT" \
  'ERROR_KIND=provider-transient'
assert_contains 'transient failures do not recommend fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'

export QWEN_FAKE_MODE=error
export QWEN_FAKE_ERROR_TYPE=authentication_error
run_cli start --cwd "$PROJECT" "Trigger an auth error."
unset QWEN_FAKE_MODE QWEN_FAKE_ERROR_TYPE
assert_contains 'auth error classifies as authentication' "$OUTPUT" \
  'ERROR_KIND=authentication'

# --- async smoke -------------------------------------------------------------

run_cli start --async --role explorer --model haiku --cwd "$PROJECT" "Trace the fake dependency."
assert_eq 'async start succeeds' '0' "$RC"
async_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
[[ -n "$async_worker_id" ]]
assert_contains 'async start returns a RUNNING receipt' "$OUTPUT" 'STATUS=RUNNING'
run_cli wait --timeout 20 "$async_worker_id"
assert_contains 'async wait reaches terminal' "$OUTPUT" 'WAIT_RESULT=TERMINAL'
run_cli status "$async_worker_id"
assert_contains 'async worker is DONE' "$OUTPUT" 'STATUS=DONE'
run_cli cancel "$async_worker_id"
assert_contains 'cancel on a finished worker reports it' "$OUTPUT" \
  'CANCEL_RESULT=ALREADY_TERMINAL'

# --- retention variable name -------------------------------------------------

run_cli start --cwd "$PROJECT" "seed worker for retention"
retention_worker="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
retention_dir="$QWEN_AGENT_HOME/workers/$retention_worker"
touch -t 202501010000 "$retention_dir"
run_cli start --cwd "$PROJECT" "trigger cleanup run"
assert_eq 'cleanup run succeeds' '0' "$RC"
[[ -d "$QWEN_AGENT_HOME/workers/$retention_worker" ]]
pass 'default retention keeps the backdated worker'
run_cli list
assert_contains 'list shows workers' "$OUTPUT" 'WORKER_ID='

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
