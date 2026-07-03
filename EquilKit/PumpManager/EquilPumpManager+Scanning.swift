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

    /// Hatótávon belüli Equil pumpák listázása (SN a BLE-névből).
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

    /// Párosítás a kiválasztott pumpával, majd auto-RUN (CmdModelSet=1).
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

        // PUMPACSERE TISZTA STATE: a párosítás ELEJÉN töröljük az ELŐZŐ pumpa credentials-ét és
        // állapotát, hogy ha az új párosítás elakad, NE maradjon új-SN + régi-token kombináció
        // (ez okozta a "régi credentials beragad pumpacserénél" hibát). A régi token csak siker
        // után íródott felül korábban — most ELŐRE törlünk.
        state.deviceToken = ""
        state.pairingPassword = ""
        state.pumpState = .none // priming-gate reset: ne maradjon .active/.primed az előző pumpától
        state.primeProgress = 0
        state.activationProgress = .none // sikerkor .priming-re lép
        state.patchId = Data()
        state.sessionToken = Data()
        state.peripheralUUID = nil // a régi BLE-azonosítót eldobjuk → friss scan az új SN-re
        commandQueue.peripheralUUID = nil
        commandQueue.bleManager.disconnect() // a régi pumpa kapcsolatát bontjuk

        state.serialNumber = sn
        state.password = pwd
        state.pairingPassword = pwd // CmdUnPair-hez (későbbi pumpa-felszabadításhoz)
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
                        // Párosítás OK, RUN nem — a priming lépés kézi RUN-t adhat.
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
