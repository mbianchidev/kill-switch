# Accessibility

KillSwitch is a native macOS SwiftUI/AppKit application with a headless JSON CLI.
Accessibility improvements are welcome. These are contribution and verification
guidelines, not a claim that the app has passed a complete accessibility audit.

## Contribution guidelines

- Use native macOS accessibility semantics and controls where possible.
  Custom controls, icons, process actions, and charts need meaningful accessible
  names, values, and state, not just tooltips or visual appearance.
- Keep navigation and actions usable with the keyboard. Preserve visible focus,
  predictable focus order, and focus after dialogs or dynamic updates.
- Expose status and failures to VoiceOver without repeatedly announcing every
  six-second process-table refresh. Include textual summaries for graphs.
- Do not rely only on color to communicate warnings, selection, protected
  items, or resource modes. Check text, controls, focus, and graph legends for
  contrast against the dark/translucent background.
- Respect Reduce Motion and macOS display preferences. Check enlarged text,
  zoom, narrow usable screen space, and long labels without hiding essential
  actions or errors.
- Give buttons and row actions usable hit targets. Destructive actions must
  remain identifiable, and disk removal must keep its confirmation.
- Keep CLI errors readable and structured on stderr; do not require color to
  interpret output. Documentation needs clear headings, descriptive links,
  image alt text, and text explanations of visual workflows.

Use [Apple's accessibility guidance](https://developer.apple.com/accessibility/)
for native behavior. WCAG 2.2 AA principles are a useful reference for contrast,
keyboard access, and documentation, not a certification of this desktop app.

## Verification

The [core checks](docs/development.md#run-checks) and
[package checks](docs/development.md#build-and-verify-the-app-and-dmg) validate
logic and distribution, not the accessibility tree or keyboard behavior.
UI changes also need manual macOS verification:

| Check | What to verify |
| --- | --- |
| Keyboard | Reach tabs, settings, dialogs, and menu-bar actions; identify focus and return to it after an action |
| VoiceOver | Understand tab names, process rows, icon-only actions, graph summaries, selected states, and errors |
| Display settings | Check Increase Contrast, Reduce Transparency, Reduce Motion, zoom, and available text-size settings |
| Layout | Test long labels and a smaller usable desktop without obscuring necessary controls |
| Dynamic content | Refreshing tables should not steal focus or flood announcements |
| Safety | Confirm protected items and destructive actions remain understandable without color |
| CLI/docs | Read JSON errors and linked instructions without relying on visual cues |

Use a disposable macOS account and synthetic files/processes for cleanup tests.
Do not exercise termination controls against real workloads or collect real
user data just to test an interface.

## Known limitations

- The window has a minimum size of **1000 x 650**, which can constrain smaller
  usable desktops and enlarged content.
- The custom dark/translucent theme, graphs, dense tables, and icon-only process
  controls require manual contrast, keyboard, and VoiceOver review.
- Some views expose explicit accessibility labels and reduced-motion behavior,
  but there is no automated accessibility UI suite or repository-wide audit
  establishing complete coverage.

No manual VoiceOver, contrast, or keyboard audit is implied by adding this guide.

## Reporting barriers

Use the [issue tracker](https://github.com/mbianchidev/kill-switch/issues) for
non-security accessibility barriers. Include macOS/app versions, the affected
workflow, assistive technology or display settings, expected behavior, and
synthetic reproduction steps. Redact personal data from screenshots and logs.
Follow [SECURITY.md](SECURITY.md) for vulnerabilities instead.
