#!/bin/bash
# offload · provider: claude   (uses the `claude` CLI in print mode — your Claude subscription)
#
# Note: --bare is NOT used — it skips keychain auth and fails with "Not logged in".
# --setting-sources "" keeps user/project settings, plugins and hooks out of the worker.
provider_claude_preflight() {
  command -v claude >/dev/null 2>&1 || { echo "offload: 'claude' CLI not found in PATH" >&2; return 1; }
}
# $1 model  $2 effort  $3 system prompt  $4 message file
provider_claude_invoke() {
  local err rc
  err=$(mktemp)
  $(offload_timeout_cmd) claude -p \
    --setting-sources "" \
    --model "$1" --effort "$2" \
    --tools "" \
    --system-prompt "$3" \
    --no-session-persistence \
    --output-format text \
    < "$4" 2>"$err"
  rc=$?
  [ -n "${OFFLOAD_DEBUG:-}" ] && [ -s "$err" ] && sed 's/^/offload[claude]: /' "$err" >&2
  rm -f "$err"
  return $rc
}
