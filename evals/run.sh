#!/bin/bash
# offload evals — hook routing decisions. No model access needed.
#   bash evals/run.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${TMPDIR:-/tmp}/offload-eval-fixtures"
# The hooks log every block. Point that at a throwaway ledger so a test run never
# pollutes the user's real savings history.
export OFFLOAD_LEDGER="${TMPDIR:-/tmp}/offload-eval-ledger.jsonl"
rm -f "$OFFLOAD_LEDGER"
PASSED=0; FAILED=0; TOTAL=0

generate_fixture() { local p="$1" n="$2"; mkdir -p "$(dirname "$p")"; if [ "$n" -eq 0 ]; then : > "$p"; else seq 1 "$n" | awk '{print "line "NR}' > "$p"; fi; }

setup_fixtures() {
  local ev="$1"; rm -rf "$FIXTURES"; mkdir -p "$FIXTURES"
  local count; count=$(jq '.evals | length' "$ev")
  for ((i=0;i<count;i++)); do
    [ "$(jq -r ".evals[$i].fixture" "$ev")" = "null" ] && continue
    local lines; lines=$(jq -r ".evals[$i].fixture.lines" "$ev")
    local p; p=$(jq -r ".evals[$i].input.tool_input.file_path // empty" "$ev")
    [ -z "$p" ] && p=$(jq -r ".evals[$i].input.tool_input.command // empty" "$ev" | python3 -c 'import sys,shlex,re
c=sys.stdin.read().strip()
c=re.split(r"&&|;",c)[-1].strip()
try: t=shlex.split(c)
except Exception: t=c.split()
if t and t[0]=="sed":
    # For sed the operand order is [flags] [script] file — take the trailing path.
    print(t[-1] if len(t)>1 else "")
    raise SystemExit
skip=False; out=""
for x in t[1:]:
    if skip: skip=False; continue
    if x in ("-n","--lines","-c"): skip=True; continue
    if x.startswith("-"): continue
    out=x; break
print(out)')
    p=$(echo "$p" | sed "s|{{FIXTURES}}|$FIXTURES|")
    case "$p" in "$FIXTURES"/*) generate_fixture "$p" "$lines" ;; esac
  done
}

decision_of() {   # normalize hook stdout → allow|block
  local out="$1"
  [ -z "$out" ] && { echo allow; return; }
  printf '%s' "$out" | jq -r 'if (.hookSpecificOutput.permissionDecision? // "") == "deny" then "block" elif (.decision? // "") != "" then .decision else "allow" end' 2>/dev/null || echo "parse-error"
}

run_eval() {
  local hook="$1" name="$2" input="$3" expected="$4" reason="$5" env_json="$6"
  TOTAL=$((TOTAL+1))
  local result
  if [ -n "$env_json" ] && [ "$env_json" != "null" ]; then
    local env_cmd=""; while IFS='=' read -r k v; do env_cmd="$env_cmd $k=$v"; done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    result=$(echo "$input" | env $env_cmd bash "$hook" 2>/dev/null || true)
  else
    result=$(echo "$input" | bash "$hook" 2>/dev/null || true)
  fi
  local actual; actual=$(decision_of "$result")
  if [ "$actual" = "$expected" ]; then printf "  \033[32mPASS\033[0m  %-28s %s\n" "$name" "$reason"; PASSED=$((PASSED+1))
  else printf "  \033[31mFAIL\033[0m  %-28s expected=%s got=%s\n" "$name" "$expected" "$actual"; FAILED=$((FAILED+1)); fi
}

run_suite() {
  local hook="$1" ev="$2" label="$3"
  setup_fixtures "$ev"; echo; echo "$label"; echo "────────────────────────────────────────────────────────────"
  local count; count=$(jq '.evals | length' "$ev")
  for ((i=0;i<count;i++)); do
    run_eval "$hook" "$(jq -r ".evals[$i].name" "$ev")" \
      "$(jq -c ".evals[$i].input" "$ev" | sed "s|{{FIXTURES}}|$FIXTURES|g")" \
      "$(jq -r ".evals[$i].expected_decision" "$ev")" "$(jq -r ".evals[$i].reason" "$ev")" \
      "$(jq -r ".evals[$i].env // empty" "$ev")"
  done
  rm -rf "$FIXTURES"
}

# Project identity: worktree layouts produce many directories per repo, so the URL
# normaliser is what keeps `gain --by-project` from degenerating into one row per folder.
run_project_suite() {
  . "$SCRIPT_DIR/../scripts/lib/common.sh"
  echo; echo "Project id (offload_project_from_url)"; echo "────────────────────────────────────────────────────────────"
  while IFS='|' read -r url expect; do
    [ -z "$url" ] && continue
    TOTAL=$((TOTAL+1))
    local got; got=$(offload_project_from_url "$url")
    if [ "$got" = "$expect" ]; then
      printf "  \033[32mPASS\033[0m  %-28s %s\n" "${url:0:28}" "-> $got"; PASSED=$((PASSED+1))
    else
      printf "  \033[31mFAIL\033[0m  %-28s expected=%s got=%s\n" "${url:0:28}" "$expect" "$got"; FAILED=$((FAILED+1))
    fi
  done <<'CASES'
git@github.com:acme/api.git|acme/api
https://github.com/acme/api.git|acme/api
https://github.com/acme/api|acme/api
https://github.com/acme/api/|acme/api
git@github-alias:user/repo.git|user/repo
ssh://git@github.com:22/acme/api.git|acme/api
https://gitlab.com/group/sub/proj.git|sub/proj
git@bitbucket.org:team/repo.git|team/repo
https://user:token@github.com/acme/api.git|acme/api
git@gitlab.company.internal:infra/tools.git|infra/tools
https://dev.azure.com/org/proj/_git/repo|proj/repo
https://github.com/WBG%20-%20Digital/app.git|WBG - Digital/app
/Users/me/local-only-repo|local-only-repo
CASES
}

# The savings report is only worth reading if its numbers are measurements. These three
# cases are the ones that turned a real ~9K saving into a reported 2.1M: media priced as if
# Read had swallowed it byte by byte, one block logged twice, and the same file counted once
# as blocked and once as delegated because the two rows spelled its path differently.
run_accounting_suite() {
  . "$SCRIPT_DIR/../scripts/lib/common.sh"
  echo; echo "Savings accounting"; echo "────────────────────────────────────────────────────────────"
  local d led got want
  d=$(mktemp -d); led="$d/ledger.jsonl"
  python3 -c "print('x = 1\n'*600, end='')" > "$d/big.py"
  cp "$d/big.py" "$d/notes.pdf"                                 # >350 "lines", but Read pages it
  head -c 40000 /dev/urandom > "$d/blob"                        # binary, no extension
  seq 1 600 > "$d/plain.txt"

  _case() {   # $1 name  $2 expected  $3 actual
    TOTAL=$((TOTAL+1))
    if [ "$3" = "$2" ]; then printf "  \033[32mPASS\033[0m  %-28s %s\n" "$1" "$2"; PASSED=$((PASSED+1))
    else printf "  \033[31mFAIL\033[0m  %-28s expected=%s got=%s\n" "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi
  }

  # 1. media and binaries are not this hook's business at all.
  for f in notes.pdf blob; do
    got=$(printf '{"tool_input":{"file_path":"%s/%s"}}' "$d" "$f" \
          | OFFLOAD_LEDGER="$led" bash "$SCRIPT_DIR/../hooks/check-file-size" 2>/dev/null || true)
    _case "media-not-blocked:$f" allow "$(decision_of "$got")"
  done
  # …while a big source file still is.
  got=$(printf '{"tool_input":{"file_path":"%s/plain.txt"}}' "$d" \
        | OFFLOAD_LEDGER="$led" bash "$SCRIPT_DIR/../hooks/check-file-size" 2>/dev/null || true)
  _case "text-still-blocked" block "$(decision_of "$got")"
  _case "media-left-no-ledger-row" 1 "$(grep -c . "$led" 2>/dev/null || echo 0)"

  # 2. a hook that fires three times for one tool call is one block, not three.
  for _ in 1 2; do
    printf '{"tool_input":{"file_path":"%s/plain.txt"}}' "$d" \
      | OFFLOAD_LEDGER="$led" bash "$SCRIPT_DIR/../hooks/check-file-size" >/dev/null 2>&1 || true
  done
  _case "duplicate-blocks-collapsed" 1 "$(grep -c '"role":"block"' "$led" 2>/dev/null || echo 0)"

  # 3. a delegation written as a relative path must cancel the block written as an absolute
  #    one — otherwise the file is billed twice, as avoided *and* as delegated.
  ( cd "$d" && OFFLOAD_LEDGER="$led" \
    OFFLOAD_LAST_IN=1000 OFFLOAD_LAST_OUT=10 OFFLOAD_LAST_SECS=1 \
    OFFLOAD_LAST_PROVIDER=test OFFLOAD_LAST_MODEL=claude-haiku-4-5 OFFLOAD_LAST_EFFORT=low \
    bash -c '. "'"$SCRIPT_DIR"'/../scripts/lib/common.sh"; offload_ledger read "[\"plain.txt\"]"' ) 2>/dev/null
  want=$(OFFLOAD_LEDGER="$led" python3 "$SCRIPT_DIR/../scripts/offload-gain" --json | jq -r .blocked_tokens_not_delegated)
  _case "delegated-file-not-double-billed" 0 "$want"
  want=$(OFFLOAD_LEDGER="$led" python3 "$SCRIPT_DIR/../scripts/offload-gain" --json | jq -r .kept_out_tokens)
  _case "kept-is-in-minus-out" 990 "$want"
  rm -rf "$d"
}

run_suite "$SCRIPT_DIR/../hooks/check-file-size" "$SCRIPT_DIR/hook-evals.json"      "Read hook (check-file-size)"
run_suite "$SCRIPT_DIR/../hooks/check-bash-read" "$SCRIPT_DIR/bash-hook-evals.json" "Bash hook (check-bash-read)"
run_project_suite
run_accounting_suite
echo; echo "════════════════════════════════════════════════════════════"
printf "Total: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, %d total\n" "$PASSED" "$FAILED" "$TOTAL"
[ "$FAILED" -gt 0 ] && exit 1; exit 0
