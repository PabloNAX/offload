---
name: bulk-reader
description: "Delegate bulk file reading to a cheaper worker model. Use when you need to read files >350 lines, answer questions across 3+ files, or summarize large diffs. The files never enter your context — only the answer does."
---

```bash
offload read --question "<question>" --paths <file1> [<file2> ...]
```

If `offload` is not on PATH, use the absolute path the blocking hook printed, or
`"${CLAUDE_PLUGIN_ROOT}/bin/offload"` when that variable is set.

Each call is independent. To ask a follow-up, ask again with the same `--paths` — the files
go to the worker, never into your context, so re-sending them costs you nothing.

Ask precise questions ("which functions call the DB and on what lines?"), not "summarize this".
Verify specific line numbers or exact values before using them in edits (re-read with offset/limit).

If you only need one known symbol, `grep -n` is cheaper than a worker call — use it instead.
