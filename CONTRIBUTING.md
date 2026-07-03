# Contributing to EquilKit-Trio

Thank you for helping improve this community Trio plugin. This project is maintained by volunteers — not Equil, Nightscout, or Trio core maintainers.

## Before you start

- Read the [README](README.md) and [INTEGRATION.md](INTEGRATION.md).
- This software is **not a medical device**. Do not claim clinical safety or efficacy in issues or PRs.
- Test on a **real device** when your change affects BLE, dosing, or UI flows. Simulator-only validation is rarely enough for pump drivers.

## How to contribute

1. **Fork** [EquilKit-Trio](https://github.com/Hristos0527/EquilKit-Trio) on GitHub.
2. Create a **feature branch** from `master` (e.g. `fix/priming-latch`).
3. Make focused changes with a clear commit message.
4. Open a **Pull Request** against `master` with:
   - What changed and why
   - How you tested (device, iOS version, Trio build)
   - Any known limitations or follow-ups
5. Respond to review feedback promptly.

## Code style

- **Swift 5**, match existing formatting in the file you edit.
- Prefer small, readable functions over clever abstractions.
- Keep UI strings and user-facing copy in **English**.
- Follow LoopKit / Trio patterns used elsewhere in this repo (`PumpManager`, `PumpManagerUI`, SwiftUI onboarding).
- Do not vendor LoopKit — assume it comes from the host Trio workspace.

## Scope

- Bug fixes and improvements to Equil BLE integration are welcome.
- Large refactors should be discussed in an issue first.
- Changes that require upstream Trio merges should note that in the PR; see [docs/UPSTREAM_PR_DRAFT.md](docs/UPSTREAM_PR_DRAFT.md) for context.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). Include device model, iOS version, Trio version, steps to reproduce, and logs (`EquilLogBuffer` export when possible).

## Disclaimer

By contributing, you agree that your contributions are licensed under the same [AGPL-3.0](LICENSE) as the project. You must not introduce medical claims, regulatory statements, or warranty language beyond the project disclaimer.
