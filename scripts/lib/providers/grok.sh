#!/bin/bash
# offload · provider: grok   (xAI Grok CLI)
provider_grok_preflight() {
  command -v grok >/dev/null 2>&1 || { echo "offload: 'grok' CLI not found in PATH" >&2; return 1; }
}
# $1 model  $2 effort  $3 system prompt  $4 message file
# grok has no effort flag; $2 is accepted and ignored so the interface stays uniform.
provider_grok_invoke() {
  local err rc args=()
  err=$(mktemp)
  [ -n "$1" ] && args+=(-m "$1")
  $(offload_timeout_cmd) grok -p "$(printf '%s\n\n' "$3"; cat "$4")" \
    "${args[@]}" --output-format plain --always-approve 2>"$err"
  rc=$?
  [ -n "${OFFLOAD_DEBUG:-}" ] && [ -s "$err" ] && sed 's/^/offload[grok]: /' "$err" >&2
  rm -f "$err"
  return $rc
}
