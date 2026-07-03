import LoopKit
import LoopKitUI
import UIKit

extension EquilPumpManager: PumpManagerUI {
    public static func setupViewController(
        initialSettings settings: PumpManagerSetupSettings,
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<any PumpManagerViewController, any PumpManagerUI> {
        let vc = EquilUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
        return .userInteractionRequired(vc)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        EquilUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes,
            opensSettingsDashboard: true
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        EquilUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures
        )
    }

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) -> HUDProvider? {
        EquilHUDProvider(
            pumpManager: self,
            bluetoothProvider: bluetoothProvider,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        EquilHUDProvider.createHUDView(rawValue: rawValue)
    }

    public static var onboardingImage: UIImage? {
        UIImage(systemName: "circle.circle")
    }

    public var smallImage: UIImage? {
        UIImage(systemName: "circle.circle.fill")
    }

    public var pumpStatusHighlight: DeviceStatusHighlight? {
        if !state.isOnboarded || state.deviceToken.isEmpty {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Not paired", comment: "Equil not paired"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }
        if state.reservoir < 5 {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Low Insulin", comment: "Equil low reservoir"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }
        if let lowBatteryWarning = state.lowBatteryWarning,
           state.battery > 0,
           state.battery <= lowBatteryWarning
        {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Low Battery", comment: "Equil low battery"),
                imageName: "battery.25",
                state: .warning
            )
        }
        if state.pumpState == .batteryOut {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Battery Empty", comment: "Equil battery empty"),
                imageName: "battery.0",
                state: .critical
            )
        }
        if state.isSuspended || state.basalDose.type == .suspend {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Insulin Suspended", comment: "Equil suspended"),
                imageName: "pause.circle.fill",
                state: .warning
            )
        }
        if Date.now.timeIntervalSince(state.lastSync) > .minutes(12) {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Signal Loss", comment: "Equil signal loss"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }
        return nil
    }

    public var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }
    public var pumpStatusBadge: DeviceStatusBadge? { nil }
}
