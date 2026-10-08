# Atlas seedling capability status

Work in progress on `seedling/atlas-harness`.

- **Files**: `Seedling.Files` (`lib/seedling/files.ex`): bounded paging, exact/tolerant disjoint edits, write, list, glob find and grep.
- **Shell/background**: `Seedling.Shell` (`lib/seedling/shell.ex`): bounded tail plus full spool, timeout/process-group cancellation, asynchronous completion mailbox event. Use `notify: {:agent, name}` for restart-safe delivery. Jobs survive agent, not node, restarts.

Foundations verified with 17 focused tests and live shell/background smoke. Other capabilities are under construction in isolated worktrees; not yet advertised as working.
