#!/usr/bin/env bash
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TEMP_BASE/provider-agent-plugin-test.XXXXXX")"

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

assert_file() {
  if [[ -f "$2" ]]; then
    pass "$1"
  else
    fail "$1" "missing file: $2"
  fi
}

marketplace_json="$REPO_DIR/.claude-plugin/marketplace.json"
assert_file 'marketplace manifest exists' "$marketplace_json"
agents_md="$(cat "$REPO_DIR/AGENTS.md")"
root_readme="$(cat "$REPO_DIR/README.md")"

assert_contains 'root README documents the marketplace' "$root_readme" \
  'claude plugin marketplace add powdream-org/provider-agent'
assert_contains 'root README installs the glm plugin' "$root_readme" \
  'claude plugin install glm-agent@provider-agent'
assert_contains 'root README installs the qwen plugin' "$root_readme" \
  'claude plugin install qwen-agent@provider-agent'
assert_contains 'AGENTS.md documents the profile contract' "$agents_md" \
  'Provider profile contract'
assert_contains 'AGENTS.md mentions the dispatch modules' "$agents_md" \
  'core/dispatch/dispatch-'
assert_contains 'AGENTS.md mentions the entry scripts' "$agents_md" \
  'scripts/<id>-dispatch'
assert_contains 'AGENTS.md mentions the dispatch suite' "$agents_md" \
  'bash tests/test_dispatch.sh'
assert_contains 'AGENTS.md keeps the key-only source rule' "$agents_md" \
  'is the only key source'
assert_contains 'AGENTS.md keeps the key-never-logged rule' "$agents_md" \
  'never be logged'

# --- per-plugin contracts --------------------------------------------------

check_plugin() {
  local id="$1" label="$2" plugin_id="${3:-$1-agent}"
  local model_var
  model_var="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')_MODEL"
  local dir="$REPO_DIR/$id"
  local plugin_json="$dir/.claude-plugin/plugin.json"
  local explorer_agent="$dir/agents/explorer.md"
  local general_agent="$dir/agents/general-purpose.md"
  local dispatch_skill="$dir/skills/dispatch/SKILL.md"
  local readme="$dir/README.md"
  local profile="$REPO_DIR/core/providers/$id.sh"
  local prefix
  prefix="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"

  assert_file "$plugin_id manifest exists" "$plugin_json"
  assert_file "$plugin_id profile exists" "$profile"
  assert_file "$plugin_id README exists" "$readme"
  assert_file "$plugin_id explorer agent exists" "$explorer_agent"
  assert_file "$plugin_id general agent exists" "$general_agent"
  assert_file "$plugin_id dispatch skill exists" "$dispatch_skill"

  if [[ -f "$plugin_json" && -f "$marketplace_json" && -f "$profile" ]]; then
    assert_eq "$plugin_id plugin name" "$plugin_id" \
      "$(jq -r '.name' "$plugin_json")"
    assert_eq "$plugin_id marketplace source" "./$id" \
      "$(jq -r --arg name "$plugin_id" \
        '.plugins[] | select(.name == $name) | .source' "$marketplace_json")"
    local profile_version plugin_version marketplace_version
    profile_version="$(sed -n "s/^PROF_VERSION='\([^']*\)'/\1/p" "$profile")"
    plugin_version="$(jq -r '.version' "$plugin_json")"
    marketplace_version="$(jq -r --arg name "$plugin_id" \
      '.plugins[] | select(.name == $name) | .version' "$marketplace_json")"
    assert_eq "$plugin_id profile and plugin versions match" \
      "$profile_version" "$plugin_version"
    assert_eq "$plugin_id profile and marketplace versions match" \
      "$profile_version" "$marketplace_version"
    if [[ "$profile_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      pass "$plugin_id release version is major.minor.patch"
    else
      fail "$plugin_id release version is major.minor.patch" \
        "got [$profile_version]"
    fi
  fi

  for agent_file in "$explorer_agent" "$general_agent"; do
    local agent_name agent_content agent_frontmatter agent_flat
    agent_name="$(basename "$agent_file" .md)"
    agent_content="$(cat "$agent_file")"
    agent_frontmatter="$(sed -n '2,/^---$/p' "$agent_file")"
    agent_flat="$(printf '%s' "$agent_content" | tr '\n' ' ' |
      sed -E 's/[[:space:]]+/ /g')"
    assert_contains "$plugin_id $agent_name uses plugin-root CLI" \
      "$agent_content" "\${CLAUDE_PLUGIN_ROOT}/${id}-agent"
    assert_contains "$plugin_id $agent_name leaves worktrees with the parent" \
      "$agent_flat" 'The parent performs all worktree operations.'
    assert_contains "$plugin_id $agent_name routes unsupported models to invalid request" \
      "$agent_flat" \
      "Complete every other $model_var value with BRIDGE_STATUS=INVALID_REQUEST."
    assert_contains "$plugin_id $agent_name reports its provider" \
      "$agent_content" "PROVIDER=$id"
    assert_contains "$plugin_id $agent_name uses native Sonnet" \
      "$agent_frontmatter" 'model: sonnet'
    assert_contains "$plugin_id $agent_name keeps Bash and Read tools" \
      "$agent_frontmatter" 'tools: Bash, Read'
    assert_contains "$plugin_id $agent_name sends TASK unchanged" \
      "$agent_flat" 'Pass TASK unchanged as the final CLI argument.'
    assert_contains "$plugin_id $agent_name uses one CLI Bash call" \
      "$agent_flat" 'Execute the selected CLI command through one Bash tool call.'
    assert_contains "$plugin_id $agent_name returns routing evidence" \
      "$agent_flat" 'Return the CLI control fields as routing evidence.'
    assert_contains "$plugin_id $agent_name waits with a bounded timeout" \
      "$agent_flat" "wait --timeout 20 \"\$WORKER_ID\""
    assert_contains "$plugin_id $agent_name routes cancellation" \
      "$agent_flat" "cancel \"\$WORKER_ID\""
    assert_contains "$plugin_id $agent_name defines launch completion" \
      "$agent_flat" 'start and send reach their destination when the CLI returns WORKER_ID, TURN, and STATUS=RUNNING.'
    assert_contains "$plugin_id $agent_name distinguishes semantic completion" \
      "$agent_flat" 'Semantic completion comes from a later wait or status response with STATUS=DONE or STATUS=BLOCKED.'
    assert_contains "$plugin_id $agent_name defines invalid request destination" \
      "$agent_content" 'BRIDGE_STATUS=INVALID_REQUEST'
  done

  if [[ -f "$dispatch_skill" ]]; then
    local dispatch_frontmatter dispatch_body dispatch_allowed
    dispatch_frontmatter="$(sed -n '2,/^---$/p' "$dispatch_skill")"
    dispatch_body="$(sed '1,/^---$/d' "$dispatch_skill")"
    dispatch_allowed="$(printf '%s\n' "$dispatch_frontmatter" |
      sed -n 's/^allowed-tools: //p')"
    assert_eq "$plugin_id dispatch skill name" 'dispatch' \
      "$(printf '%s\n' "$dispatch_frontmatter" | sed -n 's/^name: //p')"
    assert_eq "$plugin_id dispatch skill allows exactly the dispatch command" \
      "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/${id}-dispatch\" *)" \
      "$dispatch_allowed"
    assert_contains "$plugin_id dispatch skill body runs the allowed command" \
      "$dispatch_body" "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/${id}-dispatch\""
    for keyword in "${prefix}_NOT_REACHED" "${prefix}_RECEIPT" \
      "${prefix}_VERDICT" "${prefix}_STALLED" "${prefix}_STILL_RUNNING" \
      "${prefix}_WARN" --wait --max-wait --stall-timeout --task-file \
      --session "\${CLAUDE_SESSION_ID}" run_in_background \
      'timeout: 7200000' CronCreate pending attach worker-protocol NO_REPORT; do
      assert_contains "$plugin_id dispatch skill body mentions $keyword" \
        "$dispatch_body" "$keyword"
    done
    assert_contains "$plugin_id dispatch skill forbids opening the account files" \
      "$dispatch_body" ".$(printf '%s' "$id" | tr -d '\n')/accounts/"
  fi

  if [[ -f "$readme" ]]; then
    local readme_body
    readme_body="$(cat "$readme")"
    assert_contains "$plugin_id README documents marketplace add" "$readme_body" \
      'claude plugin marketplace add powdream-org/provider-agent'
    assert_contains "$plugin_id README documents plugin install" "$readme_body" \
      "claude plugin install $plugin_id@provider-agent"
    assert_contains "$plugin_id README documents the dispatch skill" \
      "$readme_body" "$plugin_id:dispatch"
    for line_name in "${prefix}_RECEIPT" "${prefix}_VERDICT" \
      "${prefix}_STALLED" "${prefix}_STILL_RUNNING"; do
      assert_contains "$plugin_id README documents $line_name" \
        "$readme_body" "$line_name"
    done
    for subcommand in start send wait cancel status result list close; do
      assert_contains "$plugin_id README lists the $subcommand command" \
        "$readme_body" "| \`$subcommand"
    done
  fi
}

check_plugin glm GLM
check_plugin qwen QWEN

# --- glm-specific contracts ------------------------------------------------

glm_readme="$(cat "$REPO_DIR/glm/README.md")"
assert_contains 'glm README documents the weekly threshold' "$glm_readme" \
  'USED_PERCENT>=98'
assert_contains 'glm README documents quota fail-open' "$glm_readme" 'fail-open'
assert_contains 'glm README documents the stdin header' "$glm_readme" \
  'curl -H @-'
assert_contains 'glm README documents the dispatch section' "$glm_readme" \
  $'\n## Dispatch\n'
assert_contains 'glm README recommends glm-dispatch from the main session' \
  "$glm_readme" 'is the recommended path'
assert_contains 'glm README marks the bridge agents as not recommended' \
  "$glm_readme" 'bridge agents are not recommended'
for line_name in GLM_BLOCKED GLM_NOT_REACHED; do
  assert_contains "glm README documents $line_name" "$glm_readme" "$line_name"
done
for option in --task-file --max-wait --stall-timeout --poll-seconds \
  --allow-path --est-credits --small; do
  assert_contains "glm README documents the dispatch option $option" \
    "$glm_readme" "$option"
done
for auth_phrase in 'glm-agent auth add personal --name' \
  'glm-agent auth add team --name' 'glm-agent auth switch' \
  'glm-agent auth remove' 'glm-agent auth list' '--api-key -' \
  'MIGRATED_ACCOUNT' \
  'https://z.ai/manage-apikey/coding-plan/team/usage-stats' \
  'api/monitor/usage/quota/limit' 'Bigmodel-Organization' \
  'Bigmodel-Project' 'one atomic step' \
  'uses the account that is active at that moment'; do
  assert_contains "glm README documents $auth_phrase" "$glm_readme" "$auth_phrase"
done

quota_skill="$REPO_DIR/glm/skills/quota/SKILL.md"
quota_rows="$REPO_DIR/tests/dispatch/quota-rows.tsv"
assert_file 'glm quota skill exists' "$quota_skill"
assert_file 'quota rows table exists' "$quota_rows"
if [[ -f "$quota_skill" ]]; then
  skill_frontmatter="$(sed -n '2,/^---$/p' "$quota_skill")"
  skill_body="$(sed '1,/^---$/d' "$quota_skill")"
  skill_allowed="$(printf '%s\n' "$skill_frontmatter" |
    sed -n 's/^allowed-tools: //p')"
  assert_eq 'quota skill name' 'quota' \
    "$(printf '%s\n' "$skill_frontmatter" | sed -n 's/^name: //p')"
  assert_eq 'quota skill allows exactly the quota command' \
    "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/glm-agent\" quota)" "$skill_allowed"
  for keyword in QUOTA_STATUS authentication quota-exhausted fail-open \
    'REMAINING=0' RESET_AT USED_PERCENT 'USED_PERCENT>=90' \
    'USED_PERCENT>=98' TIME_LIMIT '≤ 0' "exactly \`5h\` and \`1w\`" \
    'a status other than 0 or 1'; do
    assert_contains "quota skill decision table mentions $keyword" \
      "$skill_body" "$keyword"
  done
fi

if [[ -f "$REPO_DIR/glm/skills/dispatch/SKILL.md" && -f "$quota_rows" ]]; then
  glm_dispatch_body="$(sed '1,/^---$/d' "$REPO_DIR/glm/skills/dispatch/SKILL.md")"
  while IFS=$'\t' read -r row keyword; do
    assert_contains "glm dispatch skill decision table row $row mentions $keyword" \
      "$glm_dispatch_body" "$keyword"
  done <"$quota_rows"
fi

assert_not_contains 'qwen ships no quota skill' \
  "$(ls "$REPO_DIR/qwen/skills" 2>/dev/null)" 'quota'
assert_contains 'qwen profile disables the quota backend' \
  "$(cat "$REPO_DIR/core/providers/qwen.sh")" "PROF_QUOTA_BACKEND='none'"
assert_contains 'glm profile enables the monitor backend' \
  "$(cat "$REPO_DIR/core/providers/glm.sh")" "PROF_QUOTA_BACKEND='monitor'"
assert_contains 'qwen README documents the missing quota endpoint' \
  "$(cat "$REPO_DIR/qwen/README.md")" 'no key-based usage endpoint'
assert_contains 'qwen README documents the Token Plan endpoint' \
  "$(cat "$REPO_DIR/qwen/README.md")" \
  'https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic'

# --- version bump tool ------------------------------------------------------

bump_script="$REPO_DIR/scripts/bump-version.sh"
if [[ -x "$bump_script" ]]; then
  fixture="$TEST_ROOT/version fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_DIR/." "$fixture/"
  glm_version_before="$(jq -r '.plugins[] | select(.name == "glm-agent") | .version' \
    "$fixture/.claude-plugin/marketplace.json")"
  "$fixture/scripts/bump-version.sh" qwen-agent 0.2.1 \
    >"$TEST_ROOT/bump.out" 2>"$TEST_ROOT/bump.err"
  assert_eq 'bump updates qwen profile' 'qwen-agent 0.2.1' \
    "$("$fixture/qwen/qwen-agent" --version)"
  assert_eq 'bump updates qwen plugin manifest' '0.2.1' \
    "$(jq -r '.version' "$fixture/qwen/.claude-plugin/plugin.json")"
  assert_eq 'bump updates qwen marketplace entry' '0.2.1' \
    "$(jq -r '.plugins[] | select(.name == "qwen-agent") | .version' \
      "$fixture/.claude-plugin/marketplace.json")"
  assert_eq 'bump leaves glm untouched' "$glm_version_before" \
    "$(jq -r '.plugins[] | select(.name == "glm-agent") | .version' \
      "$fixture/.claude-plugin/marketplace.json")"

  "$fixture/scripts/bump-version.sh" glm-agent 9.9.9 \
    >"$TEST_ROOT/bump2.out" 2>"$TEST_ROOT/bump2.err"
  assert_eq 'bump updates glm profile' 'glm-agent 9.9.9' \
    "$("$fixture/glm/glm-agent" --version)"

  invalid_fixture="$TEST_ROOT/invalid version fixture"
  mkdir -p "$invalid_fixture"
  cp -R "$REPO_DIR/." "$invalid_fixture/"
  before_versions="$(cksum \
    "$invalid_fixture/core/providers/glm.sh" \
    "$invalid_fixture/core/providers/qwen.sh" \
    "$invalid_fixture/glm/.claude-plugin/plugin.json" \
    "$invalid_fixture/qwen/.claude-plugin/plugin.json" \
    "$invalid_fixture/.claude-plugin/marketplace.json")"
  for invalid_args in '1.2' 'glm-agent 1.2' 'glm-agent v1.2.3' '' 'other 1.2.3'; do
    # shellcheck disable=SC2086
    if "$invalid_fixture/scripts/bump-version.sh" $invalid_args \
      >"$TEST_ROOT/invalid.out" 2>"$TEST_ROOT/invalid.err"; then
      fail "invalid bump arguments [$invalid_args] are rejected" 'command succeeded'
    else
      pass "invalid bump arguments [$invalid_args] are rejected"
    fi
  done
  after_versions="$(cksum \
    "$invalid_fixture/core/providers/glm.sh" \
    "$invalid_fixture/core/providers/qwen.sh" \
    "$invalid_fixture/glm/.claude-plugin/plugin.json" \
    "$invalid_fixture/qwen/.claude-plugin/plugin.json" \
    "$invalid_fixture/.claude-plugin/marketplace.json")"
  assert_eq 'invalid bump arguments do not change files' "$before_versions" \
    "$after_versions"
fi

# --- plugin validation ------------------------------------------------------

if command -v claude >/dev/null 2>&1; then
  for id in glm qwen; do
    fixture="$TEST_ROOT/$id plugin fixture"
    mkdir -p "$fixture"
    cp -R "$REPO_DIR/$id" "$fixture/plugin"
    if validation_output="$(claude plugin validate --strict "$fixture/plugin" 2>&1)"; then
      pass "Claude validates the $id plugin from a path containing spaces"
    else
      fail "Claude validates the $id plugin from a path containing spaces" \
        "$validation_output"
    fi
  done
fi

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
