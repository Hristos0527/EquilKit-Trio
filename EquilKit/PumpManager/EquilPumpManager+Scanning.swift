import CoreBluetooth
import Foundation
import LoopKit

private var scanCallbackKey: UInt8 = 0

public enum EquilPairingError: LocalizedError {
    case invalidSerial
    case invalidPassword
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSerial:
            return "Invalid serial number (6 hex digits required)."
        case .invalidPassword:
            return "Invalid password (4 hex digits required)."
        case let .commandFailed(message):
            return message
        }
    }
}

public extension EquilPumpManager {
    struct ScannedPump: Identifiable, Equatable {
        public let id: String
        public let name: String
        public var rssi: Int
        public var serial: String
    }

    private var scanCallback: (([ScannedPump]) -> Void)? {
        get { objc_getAssociatedObject(self, &scanCallbackKey) as? (([ScannedPump]) -> Void) }
        set { objc_setAssociatedObject(self, &scanCallbackKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// List in-range Equil pumps (SN from BLE name).
    func startScanning(_ onUpdate: @escaping ([ScannedPump]) -> Void) {
        var found: [ScannedPump] = []
        scanCallback = onUpdate
        let ble = commandQueue.bleManager
        ble.nameFilterPrefix = nil
        ble.nameFilterContains = nil
        ble.diagnosticOnly = true
        ble.onDiscoverDiagnostic = { [weak self] peripheral, name in
            guard self != nil else { return }
            let clean = name.trimmingCharacters(in: .whitespaces)
            guard clean.lowercased().contains("equil") else { return }
            let id = peripheral.identifier.uuidString
            let sn = Self.serial(fromName: clean)
            if let idx = found.firstIndex(where: { $0.id == id }) {
                found[idx].rssi = 0
            } else {
                found.append(ScannedPump(id: id, name: clean, rssi: 0, serial: sn))
            }
            DispatchQueue.main.async { onUpdate(found) }
        }
        ble.startScan()
    }

    func stopScanning() {
        let ble = commandQueue.bleManager
        ble.stopScan()
        ble.diagnosticOnly = false
        ble.onDiscoverDiagnostic = nil
        scanCallback = nil
    }

    static func serial(fromName name: String) -> String {
        var sn = name.replacingOccurrences(of: "Equil - ", with: "")
        sn = sn.replacingOccurrences(of: "Equil-", with: "")
        return sn.trimmingCharacters(in: .whitespaces)
    }

    /// Pair with selected pump, then auto-RUN (CmdModelSet=1).
    func startPairing(
        serialNumber: String,
        password: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let sn = serialNumber.uppercased()
        let pwd = password.uppercased()
        guard sn.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            completion(.failure(EquilPairingError.invalidSerial))
            return
        }
        guard pwd.range(of: "^[0-9A-Fa-f]{4}$", options: .regularExpression) != nil else {
            completion(.failure(EquilPairingError.invalidPassword))
            return
        }

        // PUMP SWAP CLEAN STATE: at pairing START clear PREVIOUS pump credentials and
        // state so if new pairing stalls, no new-SN + old-token combination remains
        // (this caused "old credentials stuck on pump swap" bug). Old token only overwritten on success
        // previously — now we clear UP FRONT.
        state.deviceToken = ""
        state.pairingPassword = ""
        state.pumpState = .none // priming-gate reset: don't keep .active/.primed from previous pump
        state.primeProgress = 0
        state.activationProgress = .none // on success advances to .priming
        state.patchId = Data()
        state.sessionToken = Data()
        state.peripheralUUID = nil // drop old BLE id → fresh scan for new SN
        commandQueue.peripheralUUID = nil
        commandQueue.bleManager.disconnect() // disconnect old pump

        state.serialNumber = sn
        state.password = pwd
        state.pairingPassword = pwd // for CmdUnPair (later pump release)
        commandQueue.serialNumber = sn
        commandQueue.equilPassword = pwd

        let ble = commandQueue.bleManager
        ble.diagnosticOnly = false
        ble.stopScan()
        ble.onDiscoverDiagnostic = nil
        scanCallback = nil

        commandQueue.runPairing(
            serialNumber: sn,
            password: pwd,
            maxBolus: state.maxBolus,
            maxBasal: state.maxBasal
        ) { [weak self] result in
            guard let self else { return }
            guard result.success else {
                completion(.failure(EquilPairingError.commandFailed(result.errorMessage ?? "Pairing failed")))
                return
            }
            self.state.deviceToken = self.commandQueue.equilDevice
            self.state.password = self.commandQueue.equilPassword
            self.persistPairedPeripheralUUIDIfNeeded()
            let firmware = self.commandQueue.pairFirmwareVersion
            if !firmware.isEmpty {
                self.state.firmwareVersion = firmware
                if self.state.swVersion.isEmpty {
                    self.state.swVersion = firmware
                }
            }
            self.state.activationProgress = .priming
            self.notifyStateDidChange()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.setRunModeAfterPairing { runResult in
                    switch runResult {
                    case .success:
                        completion(.success(()))
                    case .failure:
                        // Pairing OK, RUN not — priming step may supply manual RUN.
                        completion(.success(()))
                    }
                }
            }
        }
    }

    private func setRunModeAfterPairing(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(.failure(EquilPairingError.commandFailed("No paired device token")))
            return
        }
        commandQueue.executeCmd({
            CmdModelSet(
                mode: RunMode.run.rawValue,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
        }) { [weak self] result in
            guard let self else { return }
            if result.success {
                self.state.runMode = .run
                self.state.isSuspended = false
                self.notifyStateDidChange()
                completion(.success(()))
            } else {
                completion(.failure(EquilPairingError.commandFailed(result.errorMessage ?? "RUN failed")))
            }
        }
    }
}
