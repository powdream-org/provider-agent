#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
plugin_name="${1:-}"
version="${2:-}"

[[ "$plugin_name" == glm-agent || "$plugin_name" == qwen-agent ]] || {
  printf 'usage: %s <glm-agent|qwen-agent> <major.minor.patch>\n' "${0##*/}" >&2
  exit 2
}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'usage: %s <glm-agent|qwen-agent> <major.minor.patch>\n' "${0##*/}" >&2
  exit 2
}

case "$plugin_name" in
  glm-agent) profile="$REPO_DIR/core/providers/glm.sh" ;;
  qwen-agent) profile="$REPO_DIR/core/providers/qwen.sh" ;;
esac
plugin_dir="${plugin_name%-agent}"
plugin="$REPO_DIR/$plugin_dir/.claude-plugin/plugin.json"
marketplace="$REPO_DIR/.claude-plugin/marketplace.json"

for required_file in "$profile" "$plugin" "$marketplace"; do
  [[ -f "$required_file" ]] || {
    printf 'missing versioned file: %s\n' "$required_file" >&2
    exit 2
  }
done

profile_tmp="$(mktemp "$REPO_DIR/.profile-version.XXXXXX")"
plugin_tmp="$(mktemp "$REPO_DIR/.plugin-version.XXXXXX")"
marketplace_tmp="$(mktemp "$REPO_DIR/.marketplace-version.XXXXXX")"

cleanup() {
  rm -f "$profile_tmp" "$plugin_tmp" "$marketplace_tmp"
}
trap cleanup EXIT

sed "s/^PROF_VERSION='[^']*'/PROF_VERSION='$version'/" "$profile" >"$profile_tmp"
jq --arg version "$version" '.version = $version' "$plugin" >"$plugin_tmp"
jq --arg version "$version" \
  --arg name "$plugin_name" \
  '(.plugins[] | select(.name == $name) | .version) = $version' \
  "$marketplace" >"$marketplace_tmp"

[[ "$(sed -n "s/^PROF_VERSION='\([^']*\)'/\1/p" "$profile_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update profile version' >&2
  exit 1
}
[[ "$(jq -er '.version' "$plugin_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update plugin version' >&2
  exit 1
}
[[ "$(jq -er --arg name "$plugin_name" \
  '.plugins[] | select(.name == $name) | .version' "$marketplace_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update marketplace version' >&2
  exit 1
}

chmod 644 "$profile_tmp" "$plugin_tmp" "$marketplace_tmp"
mv "$profile_tmp" "$profile"
mv "$plugin_tmp" "$plugin"
mv "$marketplace_tmp" "$marketplace"
chmod 755 "$SCRIPT_DIR/bump-version.sh"

printf 'PLUGIN=%s\n' "$plugin_name"
printf 'VERSION=%s\n' "$version"
