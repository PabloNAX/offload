#!/bin/bash
# offload · provider: antigravity   (`agy` — Google Antigravity, free Starter quota)
#
# Note: without --dangerously-skip-permissions the CLI blocks on a permission prompt
# and print mode eventually reports "timeout waiting for response". The worker only
# reads a prompt from stdin and writes an answer, so there is nothing to approve.
provider_antigravity_preflight() {
  command -v agy >/dev/null 2>&1 || { echo "offload: 'agy' (Antigravity CLI) not found in PATH" >&2; return 1; }
}
# $1 model  $2 effort  $3 system prompt  $4 message file
provider_antigravity_invoke() {
  local err rc prompt effort=()
  err=$(mktemp)
  prompt=$(printf '%s\n\n' "$3"; cat "$4")
  # agy model ids carry their own effort ("gemini-3.1-pro-low"), and the CLI rejects
  # a --effort that disagrees with the suffix ("conflicts with --effort=medium").
  # When the id already says it, let it speak for itself.
  case "$1" in
    *-low|*-medium|*-high) ;;
    *)                     effort=(--effort "$2") ;;
  esac
  # The prompt MUST be attached to the flag: a detached `--print` swallows the next
  # argument as its prompt ("--print took \"--model\" as its prompt").
  $(offload_timeout_cmd) agy --print="$prompt" \
    --model "$1" "${effort[@]+"${effort[@]}"}" \
    --output-format text \
    --dangerously-skip-permissions \
    --disable-slash-commands \
    --print-timeout "${OFFLOAD_TIMEOUT}s" 2>"$err"
  rc=$?
  [ -n "${OFFLOAD_DEBUG:-}" ] && [ -s "$err" ] && sed 's/^/offload[antigravity]: /' "$err" >&2
  rm -f "$err"
  return $rc
}
