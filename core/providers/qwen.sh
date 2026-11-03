# Provider profile: Alibaba Cloud Model Studio Qwen via its
# Anthropic-compatible endpoint (Token Plan base URL and models).
# The entry script sources this file before core/agent-core.sh. See the
# profile contract documented at the top of agent-core.sh.

PROF_ID='qwen'
PROF_LABEL='Qwen'
PROF_PROVIDER_NAME='Alibaba Cloud Model Studio'
PROF_VERSION='0.1.0'
PROF_HOME_DIR='.qwen'

# Token Plan Personal Edition endpoint per Model Studio's Claude Code guide.
PROF_DEFAULT_BASE_URL='https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic'
PROF_DEFAULT_HAIKU_MODEL='qwen3.6-flash'
PROF_DEFAULT_SONNET_MODEL='qwen3.8-flash'
PROF_DEFAULT_OPUS_MODEL='qwen3.8-max'

PROF_ENV_AGENT_HOME='QWEN_AGENT_HOME'
PROF_ENV_API_KEY='QWEN_API_KEY'
PROF_ENV_BASE_URL='QWEN_BASE_URL'
PROF_ENV_HAIKU_MODEL='QWEN_HAIKU_MODEL'
PROF_ENV_SONNET_MODEL='QWEN_SONNET_MODEL'
PROF_ENV_OPUS_MODEL='QWEN_OPUS_MODEL'
PROF_ENV_SYSTEM_PROMPT_FILE='QWEN_SYSTEM_PROMPT_FILE'
PROF_ENV_ROLE_PROMPTS_DIR='QWEN_ROLE_PROMPTS_DIR'
PROF_ENV_ROLE='QWEN_ROLE'
PROF_ENV_RESULT_FILE='QWEN_RESULT_FILE'
PROF_ENV_RETENTION_DAYS='QWEN_WORKER_RETENTION_DAYS'
PROF_ENV_DISPATCH_CLI='QWEN_DISPATCH_CLI'
PROF_ENV_QUOTA_ORGANIZATION=''
PROF_ENV_QUOTA_PROJECT=''

# Model Studio has no key-based quota endpoint for Token Plan, so this
# provider runs without the quota command and dispatch always fails open.
PROF_QUOTA_BACKEND='none'
PROF_SUPPORTS_TEAM_SCOPE='false'

PROF_CLAUDE_ENV_EXTRA=(
  ANTHROPIC_MODEL=auto
  CLAUDE_CODE_SUBAGENT_MODEL=auto
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=983616
)

# Model Studio returns Anthropic-style error objects:
# {"type":"error","error":{"type":"rate_limit_error","message":"..."}}.
# These three hooks override the Z.ai-flavoured core defaults.

extract_provider_code() {
  local response_file="$1"
  local stderr_file="$2"
  local code=""

  code="$(
    jq -r '
      if type != "object" then empty
      elif ((.error? | type) == "object") and (.error.type? != null) then
        .error.type | tostring
      elif (.error? | type) == "string" then
        .error
      elif (.is_error? == true) and ((.result? | type) == "string") then
        (try (.result |
          capture("(?i)\\b(rate_limit_error|insufficient_quota|quota_exhausted|authentication_error|permission_error|invalid_request_error|api_error|overloaded_error|not_found_error)\\b"))[0]
          catch null) // empty
      else empty
      end
    ' "$response_file" 2>/dev/null | head -n 1
  )" || true
  if [[ -n "$code" ]]; then
    printf '%s\n' "$code"
    return 0
  fi
  code="$(
    { cat "$response_file"; cat "$stderr_file"; } 2>/dev/null |
      grep -Eo '"(type|code)"[[:space:]]*:[[:space:]]*"?[A-Za-z0-9_.-]+' |
      grep -Eo '(rate_limit_error|insufficient_quota|quota_exhausted|authentication_error|permission_error|invalid_request_error|api_error|overloaded_error|not_found_error)' |
      head -n 1
  )" || true
  printf '%s\n' "$code"
}

classify_error_kind() {
  local provider_code="$1"
  local default_kind="$2"

  case "$provider_code" in
    insufficient_quota|quota_exhausted)
      printf '%s\n' 'quota-exhausted'
      ;;
    rate_limit_error|529|overloaded_error|500|api_error)
      printf '%s\n' 'provider-transient'
      ;;
    401|403|authentication_error|permission_error)
      printf '%s\n' 'authentication'
      ;;
    400|404|invalid_request_error|not_found_error)
      printf '%s\n' 'model-unavailable'
      ;;
    '') printf '%s\n' "$default_kind" ;;
    *) printf '%s\n' 'provider-error' ;;
  esac
}

provider_response_is_error() {
  local response_file="$1"

  jq -e '
    type == "object" and (
      .is_error == true
      or .subtype == "error"
      or ((.error? | type) == "object")
      or (
        ((.is_error? != false) or (.subtype? != "success"))
        and
        ((.result? | type) == "string")
        and (.result | test("(?i)(error|quota|exhausted|rate.?limit|failed|authentication|model unavailable|provider error|request failed)"))
        and (.result | test("(?i)\\b(rate_limit_error|insufficient_quota|quota_exhausted|authentication_error|permission_error|invalid_request_error|api_error|overloaded_error|not_found_error|429|401|403)\\b"))
      )
    )
  ' "$response_file" >/dev/null 2>&1
}
