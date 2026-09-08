#!/bin/bash
# offload · provider: ollama   (local models — no account, no network, no quota)
provider_ollama_preflight() {
  command -v ollama >/dev/null 2>&1 || { echo "offload: 'ollama' not found in PATH" >&2; return 1; }
  ollama list 2>/dev/null | tail -n +2 | grep -q . || {
    echo "offload: ollama has no models pulled — try: ollama pull qwen3:8b" >&2; return 1; }
}
# $1 model  $2 effort (ignored)  $3 system prompt  $4 message file
provider_ollama_invoke() {
  local err rc
  err=$(mktemp)
  { printf '%s\n\n' "$3"; cat "$4"; } | $(offload_timeout_cmd) ollama run "$1" 2>"$err"
  rc=$?
  [ -n "${OFFLOAD_DEBUG:-}" ] && [ -s "$err" ] && sed 's/^/offload[ollama]: /' "$err" >&2
  rm -f "$err"
  return $rc
}
