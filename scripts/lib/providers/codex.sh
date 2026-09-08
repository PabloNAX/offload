#!/bin/bash
# offload · provider: codex   (uses `codex exec` — your ChatGPT subscription)
provider_codex_preflight() {
  command -v codex >/dev/null 2>&1 || { echo "offload: 'codex' CLI not found in PATH" >&2; return 1; }
}
# $1 model  $2 effort  $3 system prompt  $4 message file
provider_codex_invoke() {
  local out err empty rc
  out=$(mktemp); err=$(mktemp); empty=$(mktemp -d)
  # -C <empty dir> so the worker has nothing to wander into; read-only sandbox; answer via -o.
  { printf '%s\n\n' "$3"; cat "$4"; } | $(offload_timeout_cmd) codex exec \
      -m "$1" -c "model_reasoning_effort=\"$2\"" \
      -s read-only --ephemeral --skip-git-repo-check \
      -C "$empty" -o "$out" - >/dev/null 2>"$err"
  rc=$?
  [ -n "${OFFLOAD_DEBUG:-}" ] && [ -s "$err" ] && sed 's/^/offload[codex]: /' "$err" >&2
  cat "$out"; rm -rf "$out" "$err" "$empty"
  return $rc
}
