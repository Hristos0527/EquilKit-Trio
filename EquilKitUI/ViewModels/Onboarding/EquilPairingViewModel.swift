import Foundation
import SwiftUI

@MainActor final class EquilPairingViewModel: ObservableObject {
    private let pumpManager: EquilPumpManager

    @Published var pumps: [EquilPumpManager.ScannedPump] = []
    @Published var status: String = "Searching for pumps…"
    @Published var pairing = false
    @Published var pairedOK = false
    @Published var errorText: String?

    init(pumpManager: EquilPumpManager) {
        self.pumpManager = pumpManager
    }

    func startScan() {
        status = "Searching for pumps…"
        errorText = nil
        pumpManager.startScanning { [weak self] found in
            Task { @MainActor in
                self?.pumps = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
    }

    func stopScan() {
        pumpManager.stopScanning()
    }

    func pair(with pump: EquilPumpManager.ScannedPump) {
        guard pump.serial.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            errorText = "Cannot read a valid serial number from the selected pump name."
            return
        }
        pumpManager.stopScanning()
        pairing = true
        errorText = nil
        status = "Pairing: \(pump.name)…"

        let password = pumpManager.state.password.isEmpty ? "0000" : pumpManager.state.password
        pumpManager.startPairing(serialNumber: pump.serial, password: password) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.pairing = false
                switch result {
                case .success:
                    self.pairedOK = true
                    self.status = "Paired — pump in RUN mode"
                case let .failure(error):
                    self.errorText = error.localizedDescription
                    self.status = "Pairing failed"
                    self.startScan()
                }
            }
        }
    }
}
