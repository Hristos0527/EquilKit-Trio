# Integrating EquilKit into Nightscout Trio

This guide documents the **minimal Trio-side glue code** required to use EquilKit. The kit itself lives in this repo; you wire it into your Trio fork.

> **Do not copy the entire Trio app.** Only the snippets below are needed.

## 1. Add as git submodule

From your Trio repo root:

```bash
git submodule add https://github.com/Hristos0527/EquilKit-Trio.git EquilKit
git submodule update --init --recursive
```

Or clone/copy into `EquilKit/` at the Trio workspace root (same path as MedtrumKit / OmnipodKit).

## 2. Xcode workspace

Add the project to `Trio.xcworkspace/contents.xcworkspacedata`:

```xml
<FileRef
   location = "group:EquilKit/EquilKit.xcodeproj">
</FileRef>
```

In the **Trio** app target:

1. **Link** `EquilKit.framework` (and `EquilKitUI.framework` if settings UI is embedded).
2. **Embed & Sign** both frameworks under *Frameworks, Libraries, and Embedded Content*.

## 3. Register the pump manager

**File:** `Trio/Sources/APS/DeviceDataManager.swift`

```swift
import EquilKit
```

Add to `staticPumpManagers`:

```swift
private let staticPumpManagers: [PumpManagerUI.Type] = [
    // ... existing pumps ...
    EquilPumpManager.self,
]
```

Add to `staticPumpManagersByIdentifier`:

```swift
private let staticPumpManagersByIdentifier: [String: PumpManagerUI.Type] = [
    // ... existing pumps ...
    EquilPumpManager.pluginIdentifier: EquilPumpManager.self,
]
```

## 4. Reservoir, battery, and patch dates

Still in `DeviceDataManager.swift`, when the pump manager is set (`pumpManager` `didSet`) and in `pumpManager(_:didUpdate:)`:

```swift
if let equilPump = pumpManager as? EquilPumpManager {
    pumpExpiresAtDate.send(nil)
    pumpActivatedAtDate.send(equilPump.state.activatedAt)
    storage.save(Decimal(equilPump.state.reservoir), as: OpenAPS.Monitor.reservoir)
    DispatchQueue.main.async {
        self.broadcaster.notify(PumpReservoirObserver.self, on: .main) {
            $0.pumpReservoirDidChange(Decimal(equilPump.state.reservoir))
        }
    }
    saveEquilPatchBattery(percent: equilPump.state.battery)
}
```

Add a helper — Equil `state.battery` is already **percent (0–100)**, not voltage:

```swift
/// Equil patch `state.battery` is percent (0–100, CmdHistoryGet) — NOT voltage.
private func saveEquilPatchBattery(percent rawPercent: Double) {
    guard rawPercent > 0 else { return }
    let percent = Double(min(max(rawPercent, 0), 100))
    let battery = Battery(
        percent: Int(percent),
        voltage: nil,
        string: percent > 10 ? .normal : .low,
        display: true
    )
    // ... persist to Core Data + notify PumpBatteryObserver (see Trio fork) ...
}
```

See the full implementation in a reference fork: `Trio/Sources/APS/DeviceDataManager.swift` (lines ~149–158, ~527–532, ~760–812).

## 5. Pump picker and setup flow

**File:** `Trio/Sources/Modules/PumpConfig/PumpConfigDataFlow.swift`

```swift
enum PumpType: Equatable {
    // ... existing cases ...
    case equil
}
```

**File:** `Trio/Sources/Modules/PumpConfig/View/PumpConfigRootView.swift` (and optionally `HomeRootView.swift`)

```swift
Button("Equil Patch") { state.addPump(.equil) }
```

**File:** `Trio/Sources/Modules/PumpConfig/View/PumpSetupView.swift`

```swift
import EquilKit

// inside switch on pump type:
case .equil:
    setupViewController = EquilPumpManager.setupViewController(
        initialSettings: initialSettings,
        bluetoothProvider: bluetoothManager,
        colorPalette: .default,
        allowDebugFeatures: true,
        prefersToSkipUserInteraction: false,
        allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
    )
```

## 6. Debug log export (optional)

**File:** `Trio/Sources/Modules/Settings/SettingsStateModel.swift`

```swift
import EquilKit

let equilLog = EquilLogBuffer.shared.exportText()
if equilLog != "Equil napló üres." {
    let equilURL = fileManager.temporaryDirectory.appendingPathComponent("equil-debug.log")
    try? equilLog.write(to: equilURL, atomically: true, encoding: .utf8)
    items.append(equilURL)
}
```

## 7. Plugin bundle (if using Loop-style `.loopplugin` loading)

EquilKit ships `EquilKitPlugin` implementing `PumpManagerUIPlugin`. If your Trio build loads pump plugins dynamically, ensure the plugin target is built and embedded. Most Trio forks register `EquilPumpManager` statically (step 3) and link the frameworks directly.

## 8. Build and test checklist

- [ ] Clean build Trio + EquilKit in workspace
- [ ] Pump picker shows “Equil Patch”
- [ ] Onboarding: pair → prime → activate completes
- [ ] Temp basal and bolus from Trio UI
- [ ] Background test: lock phone 5+ min — pump should not alarm “no connection” (keepalive)
- [ ] HUD shows reservoir and battery %

## Reference

- This repo: Build **#55** state (includes keepalive fix #53)
- Trio fork glue: compare against your `trio-equil-linx` fork `DeviceDataManager.swift` and `PumpConfig*` files
- AndroidAPS Equil reference: https://github.com/nightscout/AndroidAPS
