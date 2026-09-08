# offload

Your main model burns most of its context on files it read once and will never
look at again. `offload` stops that: big reads are blocked at the tool layer and
handed to a cheaper worker model, which reads the file and returns only the answer.

The file never enters your main model's context.

Works in **Claude Code** and **Codex**. Bash and `jq`. No daemon, no Docker, no
server, nothing to sign up for.

```
$ offload gain

offload Token Savings
============================================================

Tokens saved:      116.2K (98.2%)
Money saved:       $1.16
Big files caught:  37  (11 different files)
Worker calls:      14  (claude-sonnet-5)
Worker time:       3m02s (avg 13.0s)
Efficiency meter: ████████████████████████░ 98.2%
```

**Tokens saved** = tokens that would have sat in your main model's context and did
not. Either the hook stopped the read and the model answered another way, or a cheap
worker read the file and sent back a short answer instead.

`offload gain -v` adds the per-worker and per-file breakdown plus the full money
arithmetic. `offload doctor` shows what will run; `-v` adds paths and rates.

```
$ offload gain --by-project

  acme/api                 412.9K saved   $2.06   28 caught   12 calls
  acme/mobile              180.1K saved   $0.90   14 caught    5 calls
```

Grouping is by **repository, not directory** — the remote URL normalised to `org/repo`.
A git-worktree layout can put dozens of directories on one project (120 directories,
27 repos on the machine this was built on), and grouping by path would produce a row
per directory. No remote falls back to the shared git dir, then to the folder name.

`offload gain -v` adds the per-worker breakdown, the blocked files, and the money
arithmetic. `offload doctor` shows what will run; `-v` adds paths and rates.

---

## How it works

Three pieces, in order of importance:

**1. Hooks — the wall.** A `PreToolUse` hook blocks `Read` on any file over the
threshold (350 lines by default), and blocks `cat`/`less`/`more`/oversized
`head -n` in Bash. The model does not get to opt out; the block happens before
the tool runs. The denial message tells it what to do instead.

**2. Scripts — the delegation.** `offload read` sends the files to a worker model
and prints back only the answer. `offload write` generates code from a spec plus
reference files and writes it straight to disk.

**3. Ledger — the receipt.** Both the blocks and the delegations append a line to
`~/.local/share/offload/ledger.jsonl`. `offload gain` turns that into a number.

The blocks matter as much as the delegations. When the hook stops a read and the model
answers with `grep` instead, that is the *best* outcome — the file stayed out of context
and no worker was paid. If `gain` only counted worker calls it would report nothing at
all on exactly those turns, and the wall would look broken while working perfectly.

What makes this work is (1). Without the hook it is just another tool the model
forgets to use.

---

## Install

```bash
git clone https://github.com/<you>/offload.git
cd offload
./install.sh
```

That puts `offload` on your PATH and registers the plugin with every agent it
finds. Then:

```bash
offload doctor --test     # prints the config and actually calls each worker
```

Restart Claude Code afterwards so it loads the hooks.

Note: both agents copy the plugin into a cache on install. After editing the source,
re-sync it:

```bash
claude plugin marketplace update offload && claude plugin install offload@offload
codex   plugin marketplace upgrade        && codex  plugin add     offload@offload
```

<details>
<summary>Manual install</summary>

```bash
# Claude Code
claude plugin marketplace add /path/to/offload
claude plugin install offload@offload

# Codex
codex plugin marketplace add /path/to/offload
codex plugin add offload@offload

# CLI on PATH
ln -sf /path/to/offload/bin/offload ~/.local/bin/offload
```
</details>

### Do I need Docker?

No. `offload` is a handful of bash scripts. The only requirements are `bash`,
`jq`, and at least one agent CLI (`claude` or `codex`) that you are already
logged into. There is no service to run and nothing listens on a port.

---

## Codex setup

Codex hooks work natively — the wire format matches Claude Code's, and the block
lands the same way. Two things differ, and both will bite you if unset:

```toml
# ~/.codex/config.toml
[sandbox_workspace_write]
network_access = true                                  # worker calls are network calls
writable_roots = ["~/.local/share/offload"]            # so `offload gain` keeps its ledger
```

Without `network_access` every worker call fails. Without `writable_roots` the
delegation still works, but the ledger cannot be written and `offload gain` stays
empty (you get a one-line warning on stderr, not a crash).

And **inside a Codex session the worker must be `claude`, not `codex`**.
`codex exec` cannot run nested inside Codex's own seatbelt sandbox — it needs to
create PATH aliases and an in-process app-server, and both are denied
(`Operation not permitted`). `claude -p` runs there fine. `offload` picks this
default automatically; `offload doctor` warns if you override it into the broken
combination.

If you have no `claude` CLI, run Codex with a looser sandbox
(`--dangerously-bypass-approvals-and-sandbox`) or accept that only the hooks work
and the delegation does not.

---

## Choosing models

Everything is one config file. Create it:

```bash
offload config --init            # ./.offload.env  (this project)
offload config --init --global   # ~/.config/offload/config  (everywhere)
```

```bash
OFFLOAD_PROVIDER=auto            # auto | claude | codex

# Mix freely — cheap model for reading, stronger one for generating
OFFLOAD_READ_PROVIDER=codex
OFFLOAD_READ_MODEL=gpt-5.6-luna
OFFLOAD_READ_EFFORT=low

OFFLOAD_WRITE_PROVIDER=claude
OFFLOAD_WRITE_MODEL=claude-sonnet-5
OFFLOAD_WRITE_EFFORT=medium

OFFLOAD_MIN_LINES=350            # hook threshold
OFFLOAD_TIMEOUT=180              # seconds per worker call
OFFLOAD_MAIN_RATE=5              # $/1M of your MAIN model — derived from the detected model if unset
OFFLOAD_LEDGER=~/.local/share/offload/ledger.jsonl
OFFLOAD_DEBUG=1                  # show the worker CLI's stderr when a call fails
OFFLOAD_MODEL_MAP="opus:claude-sonnet-5 sonnet:claude-haiku-4-5"
```

Those twelve keys are the whole surface — anything not on the list is not read.
Effort levels are whatever the worker model supports (`low`/`medium`/`high`, and
`xhigh`/`max` on the Codex models).

Env vars beat the project file, which beats the global file. So a one-off is just:

```bash
OFFLOAD_READ_MODEL=claude-haiku-4-5 offload read --question "…" --paths big.ts
```

Defaults when you set nothing:

| Worker | read | write |
|---|---|---|
| `claude` | `claude-sonnet-5` @ low | `claude-sonnet-5` @ medium |
| `codex` | `gpt-5.6-luna` @ low | `gpt-5.6-terra` @ medium |

Run `offload doctor` to see what is actually in effect.

### Providers

Any file dropped into `scripts/lib/providers/<name>.sh` becomes a provider — two
functions, a preflight and an invoke. Shipped:

| Provider | CLI | Default read model | Account |
|---|---|---|---|
| `claude` | `claude` | `claude-sonnet-5` | Claude subscription or API key |
| `codex` | `codex` | `gpt-5.6-luna` | ChatGPT subscription |
| `antigravity` | `agy` | `gemini-3.8-flash-low` | Google account — free Starter quota |
| `grok` | `grok` | CLI default | xAI account |
| `ollama` | `ollama` | `qwen3:8b` | none — local and offline |
| `cursor` | REST API | `composer-2.5` | `CURSOR_API_KEY` |

Mix them per role: read on a free Antigravity quota, write on Sonnet.

```bash
OFFLOAD_READ_PROVIDER=antigravity
OFFLOAD_READ_MODEL=gemini-3.8-flash-low
OFFLOAD_WRITE_PROVIDER=claude
OFFLOAD_WRITE_MODEL=claude-sonnet-5
```

**`cursor` reaches the most models — and is the slowest.** One key exposes ~37 models
(Claude Opus/Sonnet/Haiku/Fable, GPT-5.x, Gemini, Grok, Kimi, GLM, Composer), which
makes it the answer when you want a model no other provider offers.

The cost is latency, and no model choice fixes it. Every call provisions a cloud
container; measured wall clock vs. the model's own reported `durationMs`:

| model | wall | model time | overhead |
|---|---|---|---|
| `composer-2.5` (fast) | 67-70s | 29s | ~40s |
| `gpt-5.6-luna` (fast) | 79s | — | — |
| `gemini-3.8-flash` low | 98s | 27s | ~70s |
| `grok-4.6` low + fast | 112-124s | 84s | ~40s |

Cursor's own `fast` toggle and the effort knobs are set automatically — but they only
touch the model time, never the ~40s floor. `composer-2.5` is the default here because
it measured fastest. Use `cursor` for `write`, or when you need a specific model;
`read` is usually better served by any CLI provider. It is never auto-selected.

Model options are validated against the API: Cursor rejects an arbitrary parameter set
(`does not match a known variant`), so the provider picks a real variant from
`GET /v1/models` — preferring fast mode, then your effort, then the smaller context —
and caches that list for a day. Override wholesale with `OFFLOAD_CURSOR_PARAMS`.

Set the key in the global config, not in a repo:

```bash
# ~/.config/offload/config
CURSOR_API_KEY=crsr_...
```

`offload doctor` lists every provider and whether its CLI is installed.
`offload doctor --test` calls the configured ones for real.

**Size limits.** `OFFLOAD_MAX_BYTES` (default 600KB) caps what goes to a worker in one
call. A provider with a lower hard ceiling overrides it: `antigravity` passes the
prompt through argv and silently truncates somewhere between 100KB and 200KB —
measured, not assumed — so it is capped at 117KB and refuses larger payloads with an
error rather than answering from a fragment.

### Automatic tiering
You usually want the worker one step below whatever is driving your session. `offload`
does that on its own: the hooks see which model is running (Codex reports it directly,
Claude Code exposes it via the session transcript), cache it per working directory, and
the scripts pick the worker from `OFFLOAD_MODEL_MAP`.

| main model | worker |
|---|---|
| Opus | Sonnet |
| Fable | Sonnet |
| Sonnet | Haiku |
| Terra / Sol / Luna | Luna |

Override the table wholesale:

```bash
OFFLOAD_MODEL_MAP="opus:claude-haiku-4-5 sonnet:claude-haiku-4-5"
```

An explicit `OFFLOAD_READ_MODEL` / `OFFLOAD_WRITE_MODEL` always wins over the map, and the
map wins over the provider default. If no hook has run yet in a directory the main model
is unknown and the provider default applies — `offload doctor` says which case you are in.

The detected model is cached in `~/.local/state/offload/hosts/`, keyed by the physical
path of the session's working directory, so parallel worktrees never read each other's.

---

## Commands

```bash
offload read   --question "which functions hit the DB, and on what lines?" \
               --paths src/api.ts src/db.ts

offload write  --spec "unit tests for UserService, cover the error paths" \
               --reference src/user.service.ts \
               --reference tests/order.service.test.ts \
               --target tests/user.service.test.ts

offload gain   [--since 7d] [--history] [--json] [--amp 32]
offload doctor [--test]
offload config [--init] [--global]
```

---

## Tuning the threshold

`OFFLOAD_MIN_LINES` is the whole trade-off in one number.

- **350** (default) — aggressive. Most real source files get delegated.
- **800** — conservative. Only genuinely large files. Start here if you are
  nervous; the quality risk nearly disappears and you still catch the worst
  offenders.

What passes through the hook no matter what:

- `Read` with `offset`/`limit` — targeted reads are never blocked, so editing
  still works normally
- `head`/`tail` with a count at or under the threshold
- pipes and redirects (`cat x | grep y`, `cat x > y`) — not reads into context
- `grep`, `rg`, and every other targeted search
- `sed -i` (editing), `sed -n '/pattern/p'`, `sed -n '100,120p'` (targeted slices)

Blocked dumpers: `cat`, `less`, `more`, `nl`, `bat`, `head`/`tail` with a count over
the threshold, and `sed` when it would print (nearly) the whole file.

The hook cannot catch everything — `awk`, `python -c`, or a custom script can always
read a file. It covers what a model actually reaches for, which in practice is `cat`
first and `sed -n '1,NNNp'` second.

### Where quality actually suffers

Be honest with yourself about this:

- **No loss:** "what does this file do", "where is X defined", "what endpoints
  exist". The worker reads, answers, you get the answer.
- **Real loss:** the worker answers exactly what you asked. Ask a narrow
  question, get a narrow answer — a detail you did not ask about is gone.
- **Real loss:** "read this whole file and get a feel for the style before
  refactoring". A summary is not the same thing. Raise the threshold or read it
  with `offset`/`limit`.

The best outcome is often that the model, on being blocked, reaches for `grep`
instead — no worker call, no tokens, exact answer.

---

## Accounting

`offload gain` reports three things and subtracts them properly.

```
Money  (main model at $5/1M in, context held for 10 turns)
────────────────────────────────────────────────────────────────────────
  Main model would have paid       $    3.0000
  Workers actually charged        -$    0.1350
  Main model still paid           -$    0.0750   (the answers it kept)

  Net saved                        $    2.7900   (93%)
```

**The worker is not free and its cost is subtracted.** Rates come from the published
list prices ($/1M in-out): Fable 5.1 `10/50`, Opus 5 `5/25`, Sonnet 5 `2/10`,
Haiku 4.5 `1/5`. A model with no rate in that table is billed at the Sonnet rate and
the report says how many calls that affected.

Worked example — Opus 5 reading one 20K-token file, answer ~500 tokens:

| | file in Opus context | delegated to Sonnet | delegated to Haiku |
|---|---|---|---|
| held 1 turn | $0.100 | $0.048 (**-53%**) | $0.025 (**-75%**) |
| held 10 turns | $1.000 | $0.070 (**-93%**) | $0.048 (**-95%**) |
| answered by `grep`, no worker | $1.000 | $0.000 (**-100%**) | — |

The worker is charged **once**; the main model's context is charged on **every turn**.
That asymmetry is the whole mechanism — and why the saving grows with conversation
length while the worker cost stays flat. `--amp N` sets how many turns to assume;
`--amp 1` (the default) is the most pessimistic reading.

### What this number does not include

- **Follow-up verification.** After a worker answers, the model often runs a `grep`
  and a narrow re-read to check it. Those tokens do enter context and are not in the
  ledger, so real savings are somewhat lower than reported.
- **Token counts are `bytes / 4`**, not a real tokenizer. Expect ±10-20% on code.
- **`offload write --target`** writes generated code to disk, so almost none of it
  enters context — but the ledger still counts those tokens as "returned". That one
  errs the other way, understating the saving.
- **On a subscription** (Claude Pro/Max, ChatGPT Plus) no dollars change hands at all.
  What you actually conserve is context window and rate-limit quota; read the dollar
  figure as a proxy for those.

## Requirements

- `bash` 3.2+ (macOS stock bash is fine)
- `jq`
- `python3` — used only by `offload gain` (ships with macOS and every Linux distro)
- `timeout` or `gtimeout` — optional, but without it worker calls cannot be
  time-limited (`brew install coreutils`)
- `claude` and/or `codex`, logged in

---

## Development

```bash
./evals/run.sh          # 62 cases, no network, no API calls
```

The evals feed JSON straight into the hook scripts. That catches parser bugs but
**not** wiring bugs — a hook that crashes on a bad path is indistinguishable from
no hook at all, because both agents fail open on hook errors. CI therefore also
checks that hook commands stay quoted and that the hooks survive junk input.
Verify real changes in a live session:

```bash
claude -p "read <big file>" --plugin-dir . --debug hooks --debug-file /tmp/h.log
grep 'permissionDecision' /tmp/h.log
```

---

## Prior art

The hook idea comes from Spotify's [`shunt`](https://github.com/spotify/portal-ai-plugins),
whose hook scripts are plain bash and work anywhere. Its delegation transport is
not portable: it calls `portal-cli actions aika:invoke-chat`, and AiKA lives
inside Spotify Portal — a commercial SaaS that Spotify hosts, sold to enterprises.
No Portal, no shunt. `offload` keeps the idea and replaces the transport with CLIs
you already have.

## License

Apache-2.0
