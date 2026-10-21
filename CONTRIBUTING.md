# Contributing to KillSwitch

Bug reports, documentation improvements, accessibility fixes, tests, and focused
code changes are welcome. Read the [Code of Conduct](CODE_OF_CONDUCT.md) and
[documentation index](docs/README.md) before getting started.

**Coding agents must read [AGENTS.md](AGENTS.md) before editing.** Everyone remains
responsible for their work, including [AI-assisted contributions](README.md#ai-policy).

## Bugs, questions, and proposals

Search [existing issues](https://github.com/mbianchidev/kill-switch/issues) first.
For bugs, include macOS version, CPU architecture, app version, installation
type, reproduction steps, expected/actual behavior, and relevant redacted
errors. Use synthetic data and check logs, command lines, file paths, screenshots,
and diagnostic archives before sharing them.

For features or substantial design changes, open an issue describing the
problem and proposed approach before implementing a large change. Do not assume
there is a support chat, fixed review turnaround, or supported platform beyond
those in the documentation.

Report vulnerabilities through the [private security process](SECURITY.md), not
public issues. Conduct reports belong with the
[Code of Conduct contact](CODE_OF_CONDUCT.md#reporting-an-issue).

## Development setup

Use macOS 13+, Git, Swift 5.9+, and Xcode Command Line Tools or Xcode. There are
no third-party Swift package dependencies or required service credentials.

The [development guide](docs/development.md) covers checkout/build commands,
code layout, safe local execution, the SDK workaround, all core checks,
packaging, and release operations. UI contributors should also read
[accessibility guidance](ACCESSIBILITY.md).

## Code, tests, and documentation

- Follow the existing Swift naming, formatting, and shared-core boundaries.
  Prefer typed models, small helpers, and comments only for non-obvious logic.
- Reuse the shared cleanup, termination-protection, preference, and installer
  logic. Preserve Porto hostagent protection and fail-closed path checks.
- Add regression coverage to the relevant executable under `Tests/`. Use mock
  processes, temporary paths, and synthetic fixtures, never real user data.
- Update the relevant guide in `docs/` when behavior, defaults, setup, or release
  requirements change. Keep the README a short landing page.
- Do not add a formatter, linter, test framework, or dependency solely to make a
  documentation change. No separate formatter/linter is currently configured.

## Pull requests

1. Fork or use a feature branch based on `main`; keep unrelated changes separate.
2. Make the change and update its tests and documentation.
3. Run the applicable [core checks](docs/development.md#run-checks) and
   [package verification](docs/development.md#build-and-verify-the-app-and-dmg)
   for code or packaging changes. For documentation-only work, check links,
   commands, and examples.
4. Use a descriptive commit message and explain the change, related issues,
   verification performed, and any untested behavior in the PR.
5. Address review feedback and failing CI before requesting another review.

Do not use the live cleanup CLI or run installation/uninstallation scripts on
your normal workstation as a test. Package checks use disposable copied apps
and invalid CLI arguments without starting the GUI or terminating processes.

Publishing is separate from local packaging. Do not create release tags or
publish artifacts merely to validate a contribution; see the
[release workflow documentation](docs/auto-update.md#release-automation).
