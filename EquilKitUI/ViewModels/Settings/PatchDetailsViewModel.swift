import HealthKit
import LoopKit
import SwiftUI

class PatchDetailsViewModel: PatchLifetimeFormatting, ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.patchDetailsViewModel")

    @Published var patchStateString: String = PatchState.none.description
    @Published var pumpBaseSN: String = ""
    @Published var swVersion: String = ""
    @Published var firmwareDisplay: String = ""
    @Published var model: String = ""
    @Published var patchId: String = ""
    @Published var battery: Double = 0
    @Published var reservoirLevel: Double = 0
    @Published var initialReservoirLevel: Double? = nil
    @Published var activatedAt: String = ""
    @Published var patchLifetime: String = ""

    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    private let pumpManager: EquilPumpManager?
    init(pumpManager: EquilPumpManager?) {
        self.pumpManager = pumpManager
        super.init()

        guard let pumpManager = pumpManager else {
            return
        }

        updateState()
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func refreshIfNeeded() {
        guard let pumpManager else { return }
        pumpManager.syncPumpData { [weak self] _ in
            pumpManager.refreshPumpBaseFirmwareIfNeeded {
                self?.updateState()
            }
        }
    }

    func batteryText(for percent: Double) -> String {
        EquilPumpState.displayBatteryText(for: percent)
    }

    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity) ?? ""
    }
}

extension PatchDetailsViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        updateState()
    }

    internal func updateState() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.patchStateString = pumpManager.state.pumpState.description
            self.model = pumpManager.state.model
            self.swVersion = pumpManager.state.swVersion
            self.firmwareDisplay = Self.displayFirmware(
                swVersion: pumpManager.state.swVersion,
                firmwareVersion: pumpManager.state.firmwareVersion
            )
            self.pumpBaseSN = pumpManager.state.pumpSN.hexEncodedString().uppercased()
            let patchIdData = pumpManager.state.patchId
            if patchIdData.isEmpty {
                self.patchId = ""
            } else if patchIdData.count <= 8 {
                self.patchId = "\(patchIdData.toUInt64())"
            } else {
                self.patchId = patchIdData.hexEncodedString().uppercased()
            }
            self.battery = pumpManager.state.battery
            self.reservoirLevel = pumpManager.state.reservoir
            self.initialReservoirLevel = pumpManager.state.initialReservoir

            if let patchActivatedAt = pumpManager.state.patchActivatedAt {
                self.activatedAt = self.dateTimeFormatter.string(from: patchActivatedAt)
                self.patchLifetime = self.processPatchLifetime(patchActivatedAt, Date())
            }
        }
    }

    private static func displayFirmware(swVersion: String, firmwareVersion: String) -> String {
        if !swVersion.isEmpty { return swVersion }
        if !firmwareVersion.isEmpty { return firmwareVersion }
        return String(localized: "—", comment: "Placeholder when pump base firmware is unavailable")
    }
}
