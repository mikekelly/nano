# Reproduce the isolated hot-upgrade proof

Use the exact private paths and effective runtime audit from the common brief, plus
`U05_TMP_ROOT=<private random tmp root>` and
`U05_OLD_SOURCE_ROOT=<private runtime directory>`.
Copy (do not symlink) the two **exact integrated base** source files into that runtime:

```
git show 6c1f15e2d19cd3bac4c96d63b6800276d008a769:lib/nano/state_store.ex > <runtime>/pre-u05-state_store.ex
git show 6c1f15e2d19cd3bac4c96d63b6800276d008a769:lib/nano_agent.ex > <runtime>/pre-u05-nano_agent.ex
mix run --no-start test/flywheel/u05/hot_upgrade.exs
```

This driver is NOT a live-node tool and is intentionally outside the default `_test.exs`
pattern: it replaces the VM's module versions before application startup. Do not run it
with the regular full suite in the same VM. It audits effective mutable config before
starting any app side effects; port 0, fake provider only, no inherited production stores.
The normal boundary/full suites run in separate fresh VMs on current proposal code.
