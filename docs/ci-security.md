# CI & security scanning

KillSwitch runs three GitHub Actions workflows:

| Workflow | File | Trigger | Purpose |
| --- | --- | --- | --- |
| CI | [`ci.yml`](../.github/workflows/ci.yml) | push / PR to `main` | `swift build -c release` smoke build |
| Release | [`release.yml`](../.github/workflows/release.yml) | push to `main` | Auto-semver release + binary (see [auto-update.md](auto-update.md)) |
| CodeQL | [`codeql.yml`](../.github/workflows/codeql.yml) | push / PR to `main`, weekly | Static analysis for `swift` and `actions` |

## CodeQL

CodeQL uses **advanced setup** (a committed workflow) rather than GitHub's
default setup, so the slow part — building Swift — is under our control.

### Why advanced setup

Default setup uses the CodeQL **autobuilder** for Swift. The autobuilder probes
for build systems and over-builds: on this ~3k-line package it took **~13 min**,
while the actual analysis was only **~1 min**. The build, not the analysis, was
the bottleneck.

### What the workflow does

- **Manual build mode** (`build-mode: manual`) for Swift. Instead of autobuild we
  run a plain debug `swift build` (~2 min). CodeQL traces that compile to build
  its database. A release build would only add optimization time with no
  analysis benefit, so debug is used.
- **`build-mode: none`** for `actions` (no compilation needed).
- **Dependency caching** of `~/Library/Caches/org.swift.swiftpm`, keyed on
  `Package.swift` / `Package.resolved`.

> **Do not cache `.build`.** CodeQL only extracts code it observes being
> compiled. A warm incremental build skips unchanged files, producing a partial
> database. Each run must compile clean — only dependency checkouts are reused.

### Enabling it (one-time)

Default setup and advanced setup are mutually exclusive. Before/when merging,
disable default setup, otherwise the workflow fails with a conflict:

- **UI:** Settings → Code security → CodeQL analysis → switch from *Default* to
  *Advanced* (or set Default to *Not configured*).
- **API:**

  ```bash
  gh api -X PATCH repos/mbianchidev/kill-switch/code-scanning/default-setup \
    -f state=not-configured
  ```

### Updating pinned versions

Actions are pinned to commit SHAs (repo convention). To bump `codeql-action`:

```bash
TAG=$(gh api repos/github/codeql-action/releases/latest -q .tag_name)
gh api repos/github/codeql-action/git/ref/tags/$TAG -q .object.sha
```

Replace the `init`/`analyze` SHAs and update the trailing `# <tag>` comment.
