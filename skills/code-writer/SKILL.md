---
name: code-writer
description: "Delegate boilerplate code generation to a cheaper worker model. Use for tests, config, docstrings, type stubs, or any generation where >80% is predictable from reference files."
---

```bash
# Generate straight to a file — the generated code never passes through your context
offload write --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Output to stdout instead (omit --target)
offload write --spec "<what to generate>" --reference <reference-file>
```

If `offload` is not on PATH, use `"${CLAUDE_PLUGIN_ROOT}/bin/offload"` when that variable is set.

`--reference` may be repeated. Each call is independent — to build on what was just
generated, pass that file as `--reference` for the next call.

Prefer `--target`. Then review the result and make surgical edits for the ~5-20%
that needs your judgment.
