#!/bin/bash
# offload · provider: cursor   (Cursor Cloud Agents REST API)
#
# One key reaches ~37 models — Claude, GPT, Gemini, Grok, Kimi, GLM — which makes this
# the most model-agnostic provider available. The catch is latency: each call provisions
# a cloud container, so expect ~60s wall clock even when the model itself takes 20s.
# Fine for `write`, usually too slow for `read`. Not an auto-detect default.
#
# Auth: CURSOR_API_KEY in the environment or in .offload.env / ~/.config/offload/config.

provider_cursor_preflight() {
  command -v curl >/dev/null 2>&1 || { echo "offload: 'curl' is required for the cursor provider" >&2; return 1; }
  [ -n "${CURSOR_API_KEY:-}" ] || {
    echo "offload: CURSOR_API_KEY is not set. Create a key at cursor.com → Settings → API Keys," >&2
    echo "        then put CURSOR_API_KEY=... in ~/.config/offload/config (never in the repo)." >&2
    return 1; }
}

# Which knobs a model accepts differs by family — effort / reasoning / reasoning_effort /
# thinking / fast / context — so ask the API instead of hardcoding a table that goes stale
# every time Cursor adds a model. Cached for a day; a per-call fetch would add latency.
_cursor_models_json() {
  local cache="${TMPDIR:-/tmp}/offload-cursor-models.json" age=999999
  if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  fi
  if [ "$age" -gt 86400 ]; then
    curl -sS -m 30 -H "Authorization: Bearer $CURSOR_API_KEY" \
      https://api.cursor.com/v1/models -o "$cache.tmp" 2>/dev/null \
      && jq -e . "$cache.tmp" >/dev/null 2>&1 && mv "$cache.tmp" "$cache" || rm -f "$cache.tmp"
  fi
  [ -f "$cache" ] && cat "$cache"
}

# model, effort -> the params of a REAL variant, as JSON.
#
# Cursor validates the whole combination, not individual knobs: sending a partial set
# gets "Model 'gpt-5.6-luna' does not match a known variant". So pick one of the
# variants the API itself lists and use its params verbatim. Preference order:
# fast mode on, requested effort, smaller context window.
_cursor_params() {
  local model="$1" effort="$2" out
  out=$(_cursor_models_json | jq -c --arg m "$model" --arg e "$effort" '
    [ .items[]? | select(.id == $m) | .variants[]? ]
    | map({ params: (.params // []), isDefault: (.isDefault // false) })
    | map(. + {
        _fast: ([ .params[]? | select(.id == "fast")    | .value ] | first // ""),
        _eff:  ([ .params[]? | select(.id == "effort" or .id == "reasoning_effort" or .id == "reasoning") | .value ] | first // ""),
        _ctx:  ([ .params[]? | select(.id == "context") | .value ] | first // "")
      })
    | map(. + { _score: (
            (if ._fast == "true" then 8 else 0 end)
          + (if ._eff == $e then 4 elif ._eff == "" then 2 else 0 end)
          + (if ._ctx == "1m" then 0 else 1 end)
          + (if .isDefault then 1 else 0 end)
        ) })
    | sort_by(-._score) | (.[0].params // [])
  ' 2>/dev/null)
  [ -z "$out" ] && out='[]'
  printf '%s' "$out"
}

# $1 model  $2 effort  $3 system prompt  $4 message file
provider_cursor_invoke() {
  local model="$1" effort="$2" params body resp agent run status result waited=0 api="https://api.cursor.com/v1"

  params=$(_cursor_params "$model" "$effort")
  [ -n "${OFFLOAD_CURSOR_PARAMS:-}" ] && params="$OFFLOAD_CURSOR_PARAMS"
  [ -n "${OFFLOAD_DEBUG:-}" ] && echo "offload[cursor]: model=$model params=$params" >&2

  body=$(jq -Rs --arg m "$model" --argjson p "$params" \
           '{prompt:{text:.}} + (if $m == "" then {} else {model:({id:$m} + (if ($p|length) > 0 then {params:$p} else {} end))} end)' \
           < <(printf '%s\n\n' "$3"; cat "$4"))

  resp=$(curl -sS -m 120 -X POST "$api/agents" \
           -H "Authorization: Bearer $CURSOR_API_KEY" -H "Content-Type: application/json" \
           -d "$body" 2>&1) || { echo "offload[cursor]: request failed: $resp" >&2; return 1; }

  agent=$(printf '%s' "$resp" | jq -r '.agent.id // empty' 2>/dev/null)
  run=$(printf   '%s' "$resp" | jq -r '.run.id // .agent.latestRunId // empty' 2>/dev/null)
  if [ -z "$agent" ] || [ -z "$run" ]; then
    echo "offload[cursor]: unexpected response: $(printf '%s' "$resp" | head -c 300)" >&2
    return 1
  fi

  while [ "$waited" -lt "$OFFLOAD_TIMEOUT" ]; do
    resp=$(curl -sS -m 30 -H "Authorization: Bearer $CURSOR_API_KEY" "$api/agents/$agent/runs/$run" 2>/dev/null)
    status=$(printf '%s' "$resp" | jq -r '.status // empty' 2>/dev/null)
    case "$status" in
      FINISHED) result=$(printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null); break ;;
      ERROR|FAILED|CANCELLED)
        echo "offload[cursor]: run $status" >&2
        curl -sS -m 15 -X DELETE "$api/agents/$agent" -H "Authorization: Bearer $CURSOR_API_KEY" >/dev/null 2>&1
        return 1 ;;
    esac
    sleep 3; waited=$((waited + 3))
  done

  # Cloud agents persist until removed; do not leave one behind per delegation.
  curl -sS -m 15 -X DELETE "$api/agents/$agent" -H "Authorization: Bearer $CURSOR_API_KEY" >/dev/null 2>&1

  [ -z "$result" ] && { echo "offload[cursor]: timed out after ${OFFLOAD_TIMEOUT}s (status=$status)" >&2; return 1; }
  printf '%s\n' "$result"
}
