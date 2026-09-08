#!/bin/bash
# offload · shared plumbing. Sourced by hooks and scripts. Defines functions only.
#
# Config priority (high → low):
#   env vars  >  ./.offload.env (project)  >  ~/.config/offload/config (user)  >  built-in defaults
#
# Keys (all optional):
#   OFFLOAD_PROVIDER        auto | claude | codex        default: auto
#   OFFLOAD_READ_PROVIDER   override provider for reads
#   OFFLOAD_WRITE_PROVIDER  override provider for code generation
#   OFFLOAD_READ_MODEL      model for reads   (per-provider default if unset)
#   OFFLOAD_WRITE_MODEL     model for writes  (per-provider default if unset)
#   OFFLOAD_READ_EFFORT     low|medium|high|…  default: low
#   OFFLOAD_WRITE_EFFORT    default: medium
#   OFFLOAD_MIN_LINES       hook threshold, default: 350
#   OFFLOAD_TIMEOUT         seconds per worker call, default: 180
#   OFFLOAD_MAIN_RATE       $/1M input tokens of your MAIN model, for `offload-gain`. default: 10 (Fable)
#   OFFLOAD_LEDGER          path to ledger jsonl

# Resolve through symlinks so the root is right even when invoked via a symlinked entrypoint.
_offload_self="${BASH_SOURCE[0]}"
while [ -L "$_offload_self" ]; do
  _offload_dir="$(cd "$(dirname "$_offload_self")" && pwd)"
  _offload_self="$(readlink "$_offload_self")"
  case "$_offload_self" in /*) ;; *) _offload_self="$_offload_dir/$_offload_self" ;; esac
done
OFFLOAD_ROOT="${OFFLOAD_ROOT:-$(cd "$(dirname "$_offload_self")/../.." && pwd)}"
unset _offload_self _offload_dir

_offload_setdefault() { if [ -z "${!1:-}" ]; then printf -v "$1" '%s' "$2"; fi; export "$1"; }

_offload_load_file() {
  local f="$1" line key val
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"
    case "$key" in OFFLOAD_*) _offload_setdefault "$key" "$val" ;; esac
  done < "$f"
}

offload_default_model() {   # $1 provider  $2 role
  case "$1:$2" in
    claude:read)       echo claude-sonnet-5 ;;
    claude:write)      echo claude-sonnet-5 ;;
    codex:read)        echo gpt-5.6-luna ;;
    codex:write)       echo gpt-5.6-terra ;;
    antigravity:read)  echo gemini-3.8-flash-low ;;
    antigravity:write) echo gemini-3.1-pro-low ;;
    grok:read)         echo "" ;;   # grok picks its own default
    grok:write)        echo "" ;;
    cursor:read)       echo composer-2.5 ;;   # fastest measured through the cloud-agent API
    cursor:write)      echo composer-2.5 ;;
    ollama:read)       echo "${OFFLOAD_OLLAMA_MODEL:-qwen3:8b}" ;;
    ollama:write)      echo "${OFFLOAD_OLLAMA_MODEL:-qwen3:8b}" ;;
    *)                 echo "" ;;
  esac
}

# Any scripts/lib/providers/<name>.sh is a provider — dropping in one file is all it takes.
offload_providers() {
  local f n
  for f in "$OFFLOAD_ROOT"/scripts/lib/providers/*.sh; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .sh); printf '%s\n' "$n"
  done
}

# Some CLIs silently truncate an oversized prompt and answer from the fragment — a wrong
# answer with no error, the worst failure available. Measured ceiling, not a guess:
# antigravity passes the prompt via argv and loses content somewhere between 100KB
# (verified good) and 200KB (verified truncated).
offload_provider_max_bytes() {
  case "$1" in
    antigravity) echo 120000 ;;
    *)           echo 0 ;;      # 0 = only the global OFFLOAD_MAX_BYTES applies
  esac
}

offload_provider_cmd() {   # provider -> the binary it needs
  case "$1" in
    antigravity) echo agy ;;
    cursor)      echo curl ;;   # REST API, no dedicated CLI
    *)           echo "$1" ;;
  esac
}

# Providers that need a key rather than a logged-in CLI.
offload_provider_key_var() {
  case "$1" in
    cursor) echo CURSOR_API_KEY ;;
    *)      echo "" ;;
  esac
}

offload_host() {
  # Which agent are we running under?  CODEX_THREAD_ID is checked first: it is set only
  # inside a live Codex turn, whereas CLAUDECODE can linger in the environment of a
  # codex process that was itself launched from Claude Code.
  if   [ -n "${CODEX_THREAD_ID:-}" ]; then echo codex
  elif [ -n "${CLAUDECODE:-}" ];     then echo claude
  else echo none; fi
}

offload_detect_provider() {
  # Which worker CLI can actually run from inside this host's sandbox?
  #
  #   Claude Code  → `claude -p` works.
  #   Codex        → `codex exec` does NOT work nested: it needs to create PATH aliases and
  #                  an in-process app-server, both denied by Codex's seatbelt sandbox
  #                  ("Operation not permitted (os error 1)").  `claude -p` does work there,
  #                  so prefer it.  Plain `codex` only works if the user loosened the sandbox.
  #   Plain shell  → either works.
  local host; host=$(offload_host)
  case "$host" in
    codex)
      command -v claude >/dev/null 2>&1 && { echo claude; return; }
      command -v codex  >/dev/null 2>&1 && { echo codex;  return; } ;;
    claude)
      command -v claude >/dev/null 2>&1 && { echo claude; return; } ;;
  esac
  local p
  for p in claude codex antigravity grok ollama; do   # cursor omitted on purpose: ~60s per call
    command -v "$(offload_provider_cmd "$p")" >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo claude
}

offload_state_dir() { printf '%s' "${OFFLOAD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/offload}"; }

# One state file per working directory, so parallel sessions (git worktrees, several
# Conductor workspaces) never read each other's host model.
offload_cwd_key() {
  local d="${1:-$PWD}"
  # Resolve to the physical path: macOS hands hooks /private/tmp/x while a shell in the
  # same directory reports /tmp/x, and the two must hash to the same key.
  d=$(cd "$d" 2>/dev/null && pwd -P) || d="${1:-$PWD}"
  if   command -v shasum   >/dev/null 2>&1; then printf '%s' "$d" | shasum      | cut -c1-16
  elif command -v sha1sum  >/dev/null 2>&1; then printf '%s' "$d" | sha1sum     | cut -c1-16
  else printf '%s' "$d" | cksum | tr -d ' ' | cut -c1-16; fi
}

# Called by the hooks, which are the only place that receives transcript_path.
# Records which model is driving this session so the scripts can pick a worker below it.
offload_record_host_model() {
  local payload="$1" tpath model dir key
  tpath=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
  model=$(printf '%s' "$payload" | jq -r '.model // empty' 2>/dev/null)   # Codex supplies it directly
  if [ -z "$model" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
    # Only the tail matters and transcripts get large — do not read the whole file.
    model=$(tail -c 200000 "$tpath" 2>/dev/null | grep -o '"model":"[^"]*"' | tail -1 | cut -d'"' -f4)
  fi
  [ -z "$model" ] && return 0
  dir=$(offload_state_dir); mkdir -p "$dir/hosts" 2>/dev/null || return 0
  key=$(offload_cwd_key "$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)")
  printf '%s\n' "$model" > "$dir/hosts/$key" 2>/dev/null || true
}

offload_host_model() {
  local dir key f d
  d=$(pwd -P 2>/dev/null) || d="$PWD"
  dir=$(offload_state_dir)
  # Walk up: the script may run in a subdirectory of the session's cwd.
  while :; do
    key=$(offload_cwd_key "$d"); f="$dir/hosts/$key"
    [ -f "$f" ] && { cat "$f"; return 0; }
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
  done
  return 1
}

# Pick a worker one tier below the model actually driving the session.
# OFFLOAD_MODEL_MAP is a space-separated list of "pattern:worker-model" pairs; the first
# pattern that matches the host model wins.
OFFLOAD_MODEL_MAP_DEFAULT="opus:claude-sonnet-5 fable:claude-sonnet-5 sonnet:claude-haiku-4-5 haiku:claude-haiku-4-5 terra:gpt-5.6-luna sol:gpt-5.6-luna luna:gpt-5.6-luna"

offload_mapped_model() {   # $1 host model  → worker model on stdout, or nothing
  local host="$1" pair pat worker
  [ -z "$host" ] && return 1
  for pair in ${OFFLOAD_MODEL_MAP:-$OFFLOAD_MODEL_MAP_DEFAULT}; do
    pat="${pair%%:*}"; worker="${pair#*:}"
    case "$host" in *"$pat"*) printf '%s' "$worker"; return 0 ;; esac
  done
  return 1
}

offload_load_config() {
  _offload_load_file "$PWD/.offload.env"
  _offload_load_file "${XDG_CONFIG_HOME:-$HOME/.config}/offload/config"
  _offload_setdefault OFFLOAD_PROVIDER auto
  [ "$OFFLOAD_PROVIDER" = auto ] && OFFLOAD_PROVIDER=$(offload_detect_provider)
  export OFFLOAD_PROVIDER
  _offload_setdefault OFFLOAD_READ_PROVIDER  "$OFFLOAD_PROVIDER"
  _offload_setdefault OFFLOAD_WRITE_PROVIDER "$OFFLOAD_PROVIDER"
  _offload_setdefault OFFLOAD_READ_EFFORT    low
  _offload_setdefault OFFLOAD_WRITE_EFFORT   medium
  _offload_setdefault OFFLOAD_MIN_LINES      350
  _offload_setdefault OFFLOAD_TIMEOUT        180
  _offload_setdefault OFFLOAD_MAX_BYTES      600000
  # Input $/1M of the model actually driving the session — no reason to make the user
  # configure a number we can read off the detected model.
  case "$(offload_host_model 2>/dev/null)" in
    *fable*|*mythos*) _offload_setdefault OFFLOAD_MAIN_RATE 10 ;;
    *opus*)           _offload_setdefault OFFLOAD_MAIN_RATE 5  ;;
    *sonnet*)         _offload_setdefault OFFLOAD_MAIN_RATE 2  ;;
    *haiku*)          _offload_setdefault OFFLOAD_MAIN_RATE 1  ;;
  esac
  _offload_setdefault OFFLOAD_MAIN_RATE      10
  _offload_setdefault OFFLOAD_LEDGER         "$HOME/.local/share/offload/ledger.jsonl"
  # Priority for the worker model:
  #   1. explicit OFFLOAD_*_MODEL (env or config file)
  #   2. OFFLOAD_MODEL_MAP matched against the model driving this session
  #   3. the provider's built-in default
  OFFLOAD_HOST_MODEL="${OFFLOAD_HOST_MODEL:-$(offload_host_model 2>/dev/null)}"
  export OFFLOAD_HOST_MODEL
  if [ -n "$OFFLOAD_HOST_MODEL" ]; then
    local mapped; mapped=$(offload_mapped_model "$OFFLOAD_HOST_MODEL")
    if [ -n "$mapped" ]; then
      case "$mapped" in
        claude-*) _offload_setdefault OFFLOAD_READ_PROVIDER claude; _offload_setdefault OFFLOAD_WRITE_PROVIDER claude ;;
        gpt-*)    : ;;   # keep the detected provider; the codex CLI serves every gpt-* worker
      esac
      _offload_setdefault OFFLOAD_READ_MODEL  "$mapped"
      _offload_setdefault OFFLOAD_WRITE_MODEL "$mapped"
    fi
  fi
  _offload_setdefault OFFLOAD_READ_MODEL     "$(offload_default_model "$OFFLOAD_READ_PROVIDER" read)"
  _offload_setdefault OFFLOAD_WRITE_MODEL    "$(offload_default_model "$OFFLOAD_WRITE_PROVIDER" write)"
  case "$OFFLOAD_MIN_LINES" in ''|*[!0-9]*) OFFLOAD_MIN_LINES=350 ;; esac
}

# --- project identity ---------------------------------------------------------
# Group by repository, never by directory: a Conductor/git worktree layout can have
# dozens of directories that are all the same project (120 dirs -> 27 repos here).
# Pure bash on purpose — this runs in a PreToolUse hook on every tool call.

offload_project_from_url() {   # remote URL -> "org/repo"
  local u="$1" path
  [ -z "$u" ] && return 1
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    /*)     printf '%s' "${u##*/}"; return 0 ;;             # a path, not a remote
    *://*)  u="${u#*://}"; u="${u#*@}"; path="${u#*/}" ;;   # scheme://[user@]host[:port]/…
    *@*:*)  path="${u#*:}" ;;                               # scp-style git@host:org/repo
    *:*/*)  path="${u#*:}" ;;                               # host:org/repo
    *)      path="$u" ;;
  esac
  path="${path#/}"
  case "$path" in */_git/*) path="${path%%/_git/*}/${path#*/_git/}" ;; esac   # Azure DevOps
  case "$path" in
    */*/*) path="${path#"${path%/*/*}/"}" ;;                # keep the last two segments
  esac
  case "$path" in *%[0-9A-Fa-f][0-9A-Fa-f]*) path=$(printf '%b' "${path//%/\\x}") ;; esac
  printf '%s' "$path"
}

offload_project() {   # -> project id for $1 (default $PWD), or "unknown"
  local d="${1:-$PWD}" url top
  url=$(git -C "$d" remote get-url origin 2>/dev/null) && [ -n "$url" ] && {
    offload_project_from_url "$url"; return 0; }
  # No remote: fall back to the shared git dir, which is one per repo across all worktrees.
  top=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) && [ -n "$top" ] && {
    top="${top%/.git}"; top="${top%/}"
    [ "$top" = ".git" ] && top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
    printf '%s' "${top##*/}"; return 0; }
  printf '%s' "${d##*/}"
}

offload_hook_deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# Record the block itself, not just the delegations that follow it.
# A blocked read that the model then solves with grep costs zero worker calls but still
# keeps the whole file out of context — without this the wall's main effect is invisible
# and `offload gain` reports nothing at all.
offload_ledger_block() {   # $1 file  $2 lines  $3 tool
  local bytes est
  bytes=$(wc -c < "$1" 2>/dev/null | tr -d ' '); bytes=${bytes:-0}
  est=$(( bytes / 4 ))
  mkdir -p "$(dirname "$OFFLOAD_LEDGER")" 2>/dev/null
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg file "$1" --arg tool "${3:-Read}" \
     --argjson lines "${2:-0}" --argjson est "$est" --arg cwd "$PWD" \
     --arg project "$(offload_project "$(dirname "$1")")" \
     '{ts:$ts,role:"block",tool:$tool,file:$file,lines:$lines,est_tokens:$est,cwd:$cwd,project:$project}' \
     >> "$OFFLOAD_LEDGER" 2>/dev/null || true
}

OFFLOAD_TMPFILES=()
offload_tmpfile() {   # usage: offload_tmpfile VARNAME
  local f; f=$(mktemp) || return 1
  OFFLOAD_TMPFILES+=("$f")
  trap 'rm -f "${OFFLOAD_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

offload_timeout_cmd() {
  if   command -v timeout  >/dev/null 2>&1; then echo "timeout $OFFLOAD_TIMEOUT"
  elif command -v gtimeout >/dev/null 2>&1; then echo "gtimeout $OFFLOAD_TIMEOUT"
  else echo ""; fi
}

# offload_invoke ROLE SYSTEM_PROMPT MESSAGE_FILE  → answer on stdout
offload_invoke() {
  local role="$1" system="$2" msg="$3" provider model effort pf answer rc start end
  case "$role" in
    read)  provider="$OFFLOAD_READ_PROVIDER";  model="$OFFLOAD_READ_MODEL";  effort="$OFFLOAD_READ_EFFORT" ;;
    write) provider="$OFFLOAD_WRITE_PROVIDER"; model="$OFFLOAD_WRITE_MODEL"; effort="$OFFLOAD_WRITE_EFFORT" ;;
    *) echo "offload: unknown role '$role'" >&2; return 1 ;;
  esac
  pf="$OFFLOAD_ROOT/scripts/lib/providers/$provider.sh"
  [ -f "$pf" ] || { echo "offload: unknown provider '$provider' — expected $pf" >&2; return 1; }
  . "$pf"
  "provider_${provider}_preflight" || return 1
  command -v jq >/dev/null 2>&1 || { echo "offload: jq is required (brew install jq)" >&2; return 1; }

  start=$(date +%s)
  answer=$("provider_${provider}_invoke" "$model" "$effort" "$system" "$msg"); rc=$?
  end=$(date +%s)
  if [ "$rc" -ne 0 ] || [ -z "$answer" ]; then
    echo "offload: $provider/$model@$effort failed (rc=$rc, empty=$([ -z "$answer" ] && echo yes || echo no))" >&2
    return 1
  fi
  OFFLOAD_LAST_IN=$(( $(wc -c < "$msg" | tr -d ' ') / 4 ))
  OFFLOAD_LAST_OUT=$(( ${#answer} / 4 ))
  OFFLOAD_LAST_PROVIDER="$provider"; OFFLOAD_LAST_MODEL="$model"; OFFLOAD_LAST_EFFORT="$effort"
  OFFLOAD_LAST_SECS=$(( end - start ))
  printf '%s\n' "$answer"
}

# offload_ledger ROLE FILES_JSON_ARRAY   — append one line, print a one-line receipt to stderr
offload_ledger() {
  local role="$1" files="$2" note=""
  mkdir -p "$(dirname "$OFFLOAD_LEDGER")" 2>/dev/null
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg role "$role" \
    --arg provider "$OFFLOAD_LAST_PROVIDER" --arg model "$OFFLOAD_LAST_MODEL" --arg effort "$OFFLOAD_LAST_EFFORT" \
    --argjson in "$OFFLOAD_LAST_IN" --argjson out "$OFFLOAD_LAST_OUT" --argjson secs "$OFFLOAD_LAST_SECS" \
    --argjson files "$files" --arg cwd "$PWD" --arg project "$(offload_project)" \
    --arg session "${CLAUDE_CODE_SESSION_ID:-}" \
    '{ts:$ts,role:$role,provider:$provider,model:$model,effort:$effort,in_tokens:$in,out_tokens:$out,secs:$secs,files:$files,cwd:$cwd,project:$project,session:$session}' \
    >> "$OFFLOAD_LEDGER" 2>/dev/null || note="  (ledger not writable: $OFFLOAD_LEDGER)"
  echo "[offload] $role → $OFFLOAD_LAST_PROVIDER/$OFFLOAD_LAST_MODEL@$OFFLOAD_LAST_EFFORT · ~${OFFLOAD_LAST_IN} tokens kept out of context, ~${OFFLOAD_LAST_OUT} returned · ${OFFLOAD_LAST_SECS}s${note}" >&2
}
