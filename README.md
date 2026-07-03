# EquilKit for Trio

![CI](https://github.com/Hristos0527/EquilKit-Trio/actions/workflows/ci.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/Hristos0527/EquilKit-Trio?label=release)
![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)

## Author

**Hristos** ([@Hristos0527](https://github.com/Hristos0527)) — developer and maintainer of this community plugin.

- Self-tested on personal daily use (~2 weeks) before release
- EquilKit: ported from AndroidAPS Equil driver reference

A **LoopKit `PumpManager` plugin** for the **Equil patch pump** (BLE), designed to integrate with [Nightscout Trio](https://github.com/nightscout/Trio) as an optional pump driver.

## Features

- Equil patch BLE pairing and onboarding (SwiftUI flow)
- Patch priming and activation
- Bolus delivery and cancel
- Temp basal (set / cancel)
- Scheduled basal sync
- Connect-per-command BLE model (connect → command → disconnect)
- **Background keepalive ping** (60–90 s jitter) to reduce pump “no connection” alarms when the app is backgrounded
- Reservoir and patch battery reporting to the host app HUD
- Debug log export (`EquilLogBuffer`) for troubleshooting

## Hardware

- **Equil patch pump** over Bluetooth Low Energy
- Tested with Equil 5.3 / 5.4 patch hardware (BLE)

## Real-world use

I have been **using this integration on myself daily for ~2 weeks** (Equil pump with Trio on iOS) before publishing.

The Equil BLE protocol integration is **based on the [AndroidAPS Equil driver](https://github.com/nightscout/AndroidAPS)** (command flow, prime, dosing patterns). It was ported and adapted for Trio's LoopKit / `PumpManager` plugin architecture — not a line-by-line copy, but the same behavioral reference implementation.

Personal testing (~2 weeks, n=1) does **not** replace clinical validation or your own safety testing.

## Modules

| Module | Role |
|--------|------|
| `EquilKit` | Core pump manager, BLE stack, command queue |
| `EquilKitUI` | SwiftUI onboarding, settings, patch lifecycle UI |
| `EquilKitPlugin` | `PumpManagerUIPlugin` entry point |

## Build requirements

- macOS with **Xcode 15+**
- **iOS 17+** deployment target (match your Trio fork)
- **LoopKit** and **LoopKitUI** (from your Trio workspace — this repo does not vendor LoopKit)
- Add `EquilKit/EquilKit.xcodeproj` to your Trio `.xcworkspace` and link `EquilKit.framework` into the Trio app target

This kit builds as a **framework** inside a Trio workspace; it is not a standalone iOS app.

## Trio integration

See **[INTEGRATION.md](INTEGRATION.md)** for step-by-step host-app changes (submodule, Xcode, `DeviceDataManager`, pump picker).

Reference fork: integrate alongside existing pump plugins (OmnipodKit, MedtrumKit, etc.).

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)**.

## License

[AGPL-3.0](LICENSE) — consistent with LoopKit / Trio.

## Disclaimer

This software is provided **as-is** for **experienced developers** who build and install Trio themselves.

- **Not a medical device.** Not reviewed or approved by any regulatory authority.
- **Use at your own risk.** You are solely responsible for building, installing, configuring, and operating this software with your pump.
- **No warranty.** The authors and contributors assume **no liability** for hypo/hyperglycemia, incorrect dosing, pump failure, or any harm arising from use or misuse.
- **Not official support** from Equil, Nightscout, or Trio maintainers unless explicitly stated.
- **Test thoroughly** with backup therapy and supervision appropriate to your situation before relying on it overnight or for automated insulin delivery.

By building or using this code, you accept full responsibility for your diabetes management decisions.
