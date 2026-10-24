# CI & security scanning

[Documentation index](README.md) | [Development checks](development.md#run-checks)

KillSwitch runs three GitHub Actions workflows:

| Workflow | File | Trigger | Purpose |
| --- | --- | --- | --- |
| CI | [`ci.yml`](../.github/workflows/ci.yml) | push / PR to `main` | Five core-check executables, universal app/DMG packaging, package verification, and DMG artifact upload |
| Release | [`release.yml`](../.github/workflows/release.yml) | push to `main` | Auto-semver release with universal DMG, standalone binary, tarball, and checksums (see [auto-update.md](auto-update.md)) |
| CodeQL | [`codeql.yml`](../.github/workflows/codeql.yml) | push / PR to `main`, weekly | Static analysis for `swift` and `actions` |

## CI runtime

New commits to a PR cancel its older CI runs, avoiding obsolete core checks and
universal packaging. Different PRs and individual pushes to `main` use separate
concurrency groups, so they do not cancel one another. The release workflow
retains its separate, non-canceling publication group.

CI still runs all five core checks and package verification for draft and ready
PRs and pushes to `main`. The DMG artifact disables upload compression because
the packaging script already creates a compressed UDZO disk image.

## CodeQL

CodeQL uses **advanced setup** (a committed workflow) rather than GitHub's
default setup, so the slow part (building Swift) is under our control.

### Why advanced setup

Default setup uses the CodeQL **autobuilder** for Swift. The autobuilder probes
for build systems and over-builds: on this ~3k-line package it took **~13 min**,
while the actual analysis was only **~1 min**. The build, not the analysis, was
the bottleneck. These are historical tuning observations, not a benchmark of
the current package size or hosted-runner performance.

### What the workflow does

- **Manual build mode** (`build-mode: manual`) for Swift. Instead of autobuild we
  run a clean debug `swift build` of all targets, with the worker count set to
  the runner's logical CPU count. CodeQL traces that compile to build its
  database. A release build would only add optimization time with no analysis
  benefit, so debug is used.
- **`build-mode: none`** for `actions` (no compilation needed).
- **No SwiftPM dependency cache:** this package has no third-party dependencies,
  so restoring and saving a dependency cache adds work without reusing any
  dependency downloads.

> **Do not cache `.build`.** CodeQL only extracts code it observes being
> compiled. A warm incremental build skips unchanged files, producing a partial
> database. Each run must compile clean after CodeQL initialization, including
> the app, update helper, shared core targets, and check executables.

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
