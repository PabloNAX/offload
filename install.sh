#!/bin/bash
# offload · installer — puts `offload` on your PATH and registers the plugin with
# whichever agents you have installed.  Re-running it is safe.
#
#   ./install.sh                install for every agent found
#   ./install.sh --cli-only     just the PATH symlink
#   ./install.sh --uninstall    undo

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${OFFLOAD_BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/offload"
ok="\033[32m✔\033[0m"; bad="\033[31m✘\033[0m"; warn="\033[33m!\033[0m"

mode=install; cli_only=0
for a in "$@"; do
  case "$a" in
    --uninstall) mode=uninstall ;;
    --cli-only)  cli_only=1 ;;
    -h|--help)   sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

if [ "$mode" = uninstall ]; then
  [ -L "$LINK" ] && rm -f "$LINK" && printf '%b removed %s\n' "$ok" "$LINK"
  command -v claude >/dev/null 2>&1 && { claude plugin uninstall offload >/dev/null 2>&1 && printf '%b claude: plugin removed\n' "$ok"; }
  command -v codex  >/dev/null 2>&1 && { codex plugin remove offload@offload >/dev/null 2>&1 && printf '%b codex: plugin removed\n' "$ok"; }
  printf '\nMarketplaces were left registered. Remove them with:\n'
  printf '  claude plugin marketplace remove offload\n  codex plugin marketplace remove offload\n'
  exit 0
fi

printf '\ninstalling offload from %s\n\n' "$ROOT"

# ---- dependencies
missing=0
for dep in bash jq; do
  command -v "$dep" >/dev/null 2>&1 || { printf '%b missing required dependency: %s\n' "$bad" "$dep"; missing=1; }
done
[ "$missing" -eq 1 ] && { printf '\ninstall them first (macOS: brew install jq)\n\n'; exit 1; }
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || \
  printf '%b no timeout/gtimeout — worker calls will not be time-limited (brew install coreutils)\n' "$warn"

# ---- CLI on PATH
mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/offload" "$LINK"
printf '%b %s -> bin/offload\n' "$ok" "$LINK"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '%b %s is not on your PATH. Add to your shell rc:\n    export PATH="%s:$PATH"\n' "$warn" "$BIN_DIR" "$BIN_DIR" ;;
esac

[ "$cli_only" -eq 1 ] && { printf '\ndone. run: offload doctor\n\n'; exit 0; }

# ---- Claude Code
if command -v claude >/dev/null 2>&1; then
  if claude plugin marketplace add "$ROOT" >/dev/null 2>&1 || true; then :; fi
  if claude plugin install offload@offload >/dev/null 2>&1; then
    printf '%b claude: plugin installed (restart Claude Code to load the hooks)\n' "$ok"
  else
    printf '%b claude: automatic install failed — run manually:\n' "$warn"
    printf '    claude plugin marketplace add "%s"\n    claude plugin install offload@offload\n' "$ROOT"
  fi
else
  printf '·  claude CLI not found — skipping\n'
fi

# ---- Codex
if command -v codex >/dev/null 2>&1; then
  codex plugin marketplace add "$ROOT" >/dev/null 2>&1 || true
  if codex plugin add offload@offload >/dev/null 2>&1; then
    printf '%b codex: plugin installed\n' "$ok"
    printf '   %b codex needs two settings for the worker to run — see README "Codex setup"\n' "$warn"
  else
    printf '%b codex: automatic install failed — run manually:\n' "$warn"
    printf '    codex plugin marketplace add "%s"\n    codex plugin add offload@offload\n' "$ROOT"
  fi
else
  printf '·  codex CLI not found — skipping\n'
fi

printf '\ndone.\n\n  offload doctor --test    verify the workers answer\n  offload gain             see what you saved\n\n'
