import Foundation
import LoopKit

public class EquilPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue

    public required init(rawValue: RawValue) {
        serialNumber = rawValue["serialNumber"] as? String ?? ""
        password = rawValue["password"] as? String ?? ""
        pairingPassword = rawValue["pairingPassword"] as? String ?? ""
        deviceToken = rawValue["deviceToken"] as? String ?? ""
        peripheralUUID = rawValue["peripheralUUID"] as? String
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        lastSync = rawValue["lastSync"] as? Date ?? Date.distantPast
        reservoir = rawValue["reservoir"] as? Double ?? 0
        maxBolus = rawValue["maxBolus"] as? Double ?? 25
        maxBasal = rawValue["maxBasal"] as? Double ?? 15
        firmwareVersion = rawValue["firmwareVersion"] as? String ?? ""

        if let progressRaw = rawValue["activationProgress"] as? Int,
           let progress = ActivationProgress(rawValue: progressRaw)
        {
            activationProgress = progress
        } else {
            activationProgress = .none
        }

        if let runModeRaw = rawValue["runMode"] as? Int,
           let mode = RunMode(rawValue: runModeRaw)
        {
            runMode = mode
        } else {
            runMode = .none
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        if let rawBasalSchedule = rawValue["basalSchedule"] as? [[String: Any]] {
            basalSchedule = Self.decodeBasalSchedule(rawBasalSchedule)
        } else {
            basalSchedule = BasalSchedule.fromHourlyRates(Array(repeating: 0, count: 24))
        }

        if let rawDoseEntry = rawValue["bolusDose"] as? UnfinalizedDose.RawValue {
            bolusDose = UnfinalizedDose(rawValue: rawDoseEntry)
        }

        if let rawDoseEntry = rawValue["basalDose"] as? UnfinalizedDose.RawValue {
            basalDose = UnfinalizedDose(rawValue: rawDoseEntry)
                ?? UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        } else {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        }

        historyIndex = rawValue["historyIndex"] as? Int ?? 0
        isSuspended = rawValue["isSuspended"] as? Bool ?? false
        activatedAt = rawValue["activatedAt"] as? Date
        if let ps = rawValue["pumpState"] as? UInt8, let patch = PatchState(rawValue: ps) {
            pumpState = patch
        }
        primeProgress = rawValue["primeProgress"] as? UInt8 ?? 0

        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        if let alarmModeStored = rawValue["alarmModeRaw"] as? Int {
            alarmModeRaw = alarmModeStored
        } else if let alarmRaw = rawValue["alarmSetting"] as? UInt8 {
            alarmModeRaw = Self.migrateMedtrumAlarmSetting(alarmRaw)
        } else {
            alarmModeRaw = AlarmMode.tone.rawValue
        }
        savedAlarmModeBeforeSuspend = rawValue["savedAlarmModeBeforeSuspend"] as? Int
        userExplicitAlarmMode = rawValue["userExplicitAlarmMode"] as? Bool ?? false
        if let alarmRaw = rawValue["alarmSetting"] as? UInt8,
           let alarm = AlarmSettings(rawValue: alarmRaw)
        {
            alarmSetting = alarm
        } else {
            alarmSetting = .BeepOnly
        }
        if let expiryRaw = rawValue["expiryMode"] as? Int,
           let expiry = ExpiryMode(rawValue: expiryRaw)
        {
            expiryMode = expiry
        } else {
            expiryMode = .default
        }
        notificationAfterActivation = rawValue["notificationAfterActivation"] as? TimeInterval ?? .hours(70)
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? Double
        if let storedBatteryWarning = rawValue["lowBatteryWarning"] as? Double {
            lowBatteryWarning = Self.migrateStoredBatteryLevel(storedBatteryWarning)
        }
        initialReservoir = rawValue["initialReservoir"] as? Double
        battery = Self.migrateStoredBatteryLevel(rawValue["battery"] as? Double ?? 0)
        patchId = Self.decodePersistedData(
            hex: rawValue["patchIdHex"] as? String,
            legacyData: rawValue["patchId"] as? Data
        )
        sessionToken = Self.decodePersistedData(
            hex: rawValue["sessionTokenHex"] as? String,
            legacyData: rawValue["sessionToken"] as? Data
        )
        if let previousPatchRaw = rawValue["previousPatch"] as? Data {
            previousPatch = try? JSONDecoder().decode(PreviousPatch.self, from: previousPatchRaw)
        }
        swVersion = rawValue["swVersion"] as? String ?? firmwareVersion
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        lastTimeSetAt = rawValue["lastTimeSetAt"] as? Date
        lastTimeSetGMTOffset = rawValue["lastTimeSetGMTOffset"] as? Int
    }

    func clone() -> EquilPumpState {
        let copy = EquilPumpState(nil)
        copy.serialNumber = serialNumber
        copy.password = password
        copy.pairingPassword = pairingPassword
        copy.deviceToken = deviceToken
        copy.peripheralUUID = peripheralUUID
        copy.isOnboarded = isOnboarded
        copy.activationProgress = activationProgress
        copy.runMode = runMode
        copy.reservoir = reservoir
        copy.lastSync = lastSync
        copy.maxBolus = maxBolus
        copy.maxBasal = maxBasal
        copy.firmwareVersion = firmwareVersion
        copy.insulinType = insulinType
        copy.basalSchedule = basalSchedule
        copy.bolusDose = bolusDose
        copy.basalDose = basalDose
        copy.historyIndex = historyIndex
        copy.isSuspended = isSuspended
        copy.activatedAt = activatedAt
        copy.pumpState = pumpState
        copy.primeProgress = primeProgress
        copy.patchId = patchId
        copy.maxHourlyInsulin = maxHourlyInsulin
        copy.maxDailyInsulin = maxDailyInsulin
        copy.alarmModeRaw = alarmModeRaw
        copy.savedAlarmModeBeforeSuspend = savedAlarmModeBeforeSuspend
        copy.userExplicitAlarmMode = userExplicitAlarmMode
        copy.alarmSetting = alarmSetting
        copy.expiryMode = expiryMode
        copy.notificationAfterActivation = notificationAfterActivation
        copy.lowReservoirWarning = lowReservoirWarning
        copy.initialReservoir = initialReservoir
        copy.battery = battery
        copy.sessionToken = sessionToken
        copy.previousPatch = previousPatch
        copy.swVersion = swVersion
        copy.deviceType = deviceType
        copy.lastTimeSetAt = lastTimeSetAt
        copy.lastTimeSetGMTOffset = lastTimeSetGMTOffset
        return copy
    }

    public init(_ basal: BasalRateSchedule?) {
        serialNumber = ""
        password = ""
        pairingPassword = ""
        deviceToken = ""
        peripheralUUID = nil
        isOnboarded = false
        activationProgress = .none
        runMode = .none
        lastSync = Date.distantPast
        reservoir = 0
        maxBolus = 25
        maxBasal = 15
        firmwareVersion = ""
        bolusDose = nil
        historyIndex = 0
        isSuspended = false
        activatedAt = nil
        pumpState = .none
        primeProgress = 0
        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        alarmModeRaw = AlarmMode.tone.rawValue
        alarmSetting = .BeepOnly
        expiryMode = .default
        notificationAfterActivation = .hours(70)
        patchId = Data()
        sessionToken = Data()
        swVersion = ""
        deviceType = 0

        if let basal {
            basalSchedule = Self.makeBasalSchedule(from: basal.items)
        } else {
            basalSchedule = BasalSchedule.fromHourlyRates(Array(repeating: 0, count: 24))
        }

        basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        value["serialNumber"] = serialNumber
        value["password"] = password
        value["pairingPassword"] = pairingPassword
        value["deviceToken"] = deviceToken
        value["peripheralUUID"] = peripheralUUID
        value["isOnboarded"] = isOnboarded
        value["activationProgress"] = activationProgress.rawValue
        value["runMode"] = runMode.rawValue
        value["lastSync"] = lastSync
        value["reservoir"] = reservoir
        value["maxBolus"] = maxBolus
        value["maxBasal"] = maxBasal
        value["firmwareVersion"] = firmwareVersion
        value["insulinType"] = insulinType?.rawValue
        value["basalSchedule"] = Self.encodeBasalSchedule(basalSchedule)
        value["bolusDose"] = bolusDose?.rawValue
        value["basalDose"] = basalDose.rawValue
        value["historyIndex"] = historyIndex
        value["isSuspended"] = isSuspended
        value["activatedAt"] = activatedAt
        value["pumpState"] = pumpState.rawValue
        value["primeProgress"] = primeProgress
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["alarmModeRaw"] = alarmModeRaw
        value["savedAlarmModeBeforeSuspend"] = savedAlarmModeBeforeSuspend
        value["userExplicitAlarmMode"] = userExplicitAlarmMode
        value["alarmSetting"] = alarmSetting.rawValue
        value["expiryMode"] = expiryMode.rawValue
        value["notificationAfterActivation"] = notificationAfterActivation
        value["lowReservoirWarning"] = lowReservoirWarning
        value["lowBatteryWarning"] = lowBatteryWarning
        value["initialReservoir"] = initialReservoir
        value["battery"] = battery
        value["patchIdHex"] = patchId.hexEncodedString()
        value["sessionTokenHex"] = sessionToken.hexEncodedString()
        if let previousPatch, let encoded = try? JSONEncoder().encode(previousPatch) {
            value["previousPatch"] = encoded
        }
        value["swVersion"] = swVersion
        value["deviceType"] = deviceType
        value["lastTimeSetAt"] = lastTimeSetAt
        value["lastTimeSetGMTOffset"] = lastTimeSetGMTOffset
        return value
    }

    public var serialNumber: String
    public var password: String
    /// Az EREDETI párosító jelszó (a felhasználó 4-hex jelszava), amivel a pumpa párosítva lett.
    /// A `password` a sikeres párosítás után a kialkudott 64-hex device-jelszóra íródik felül,
    /// de a CmdUnPair (pumpa felszabadítása) az EREDETI párosító jelszót igényli (SN-származtatott
    /// kulcs + getEquilPassWord(pairingPassword)), ezért külön megőrizzük. Pumpacserénél törlődik.
    public var pairingPassword: String = ""
    /// Negotiated device hex from CmdPair (AAPS equilDevice).
    public var deviceToken: String
    public var peripheralUUID: String?
    public var isOnboarded: Bool
    public var activationProgress: ActivationProgress
    public var runMode: RunMode
    public var reservoir: Double
    public var lastSync: Date
    public var maxBolus: Double
    public var maxBasal: Double
    public var firmwareVersion: String
    public var insulinType: InsulinType?
    public var basalSchedule: BasalSchedule
    public var bolusDose: UnfinalizedDose?
    public var basalDose: UnfinalizedDose
    public var historyIndex: Int
    public var isSuspended: Bool
    public var activatedAt: Date?
    /// Medtrum-compatible onboarding UI state (Equil maps fill/prime progress here).
    public var pumpState: PatchState = .none
    public var primeProgress: UInt8 = 0

    public var patchId = Data()
    public var maxHourlyInsulin: Double = 20
    public var maxDailyInsulin: Double = 100
    /// CmdAlarmSet mode (0=mute, 1=tone, 2=shake, 3=tone+shake).
    public var alarmModeRaw: Int = AlarmMode.tone.rawValue
    /// Az átmeneti MUTE előtti alarm-mód (suspend / zero-temp idejére mentve). Resume-nál
    /// ezt állítjuk vissza, majd töröljük (nil). nil = nincs aktív átmeneti mute.
    public var savedAlarmModeBeforeSuspend: Int?
    /// true, ha a felhasználó a dashboard alarm pickerből választott módot (setAlarmMode persist:true).
    /// Suspend/temp0 után csak ilyenkor állítunk vissza nem-néma módot; egyébként Silent marad.
    public var userExplicitAlarmMode: Bool = false
    public var alarmSetting: AlarmSettings = .BeepOnly
    public var expiryMode: ExpiryMode = .default
    public var notificationAfterActivation: TimeInterval = .hours(70)
    public var lowReservoirWarning: Double?
    public var lowBatteryWarning: Double?
    public var initialReservoir: Double?
    /// Patch battery charge 0–100% (CmdHistoryGet byte; sync voltageB mapped via `batteryPercent(fromPatchVoltage:)`).
    public var battery: Double = 0

    /// CmdHistoryGet reports patch battery as 0–100% (same as Loop EquilPumpKit).
    /// A 0 érték gyakran „nincs adat” (üres history rekord), nem tényleges 0% — ne írjuk felül
    /// a sync/MASK_BATTERY-ből már beolvasott százalékot (különben a HUD eltűnik).
    func applyHistoryBattery(_ percent: Int) {
        guard percent > 0 else { return }
        battery = Double(min(100, max(0, percent)))
    }

    /// 0…1 töltöttség a Loop `pumpBatteryChargeRemaining` / Trio HUD számára; nil = még nincs olvasás.
    var patchBatteryFraction: Double? {
        guard battery > 0 else { return nil }
        return min(max(battery / 100.0, 0), 1)
    }

    /// Legacy sync MASK_BATTERY voltageB (~2.0–3.2 V) → percent.
    static func batteryPercent(fromPatchVoltage voltage: Double) -> Double {
        guard voltage > 0 else { return 0 }
        let percent = (voltage - 2.0) / 1.2 * 100.0
        return min(100, max(0, percent))
    }

    static func displayBatteryText(for percent: Double) -> String {
        guard percent > 0 else {
            return String(localized: "—", comment: "Placeholder when battery is unavailable")
        }
        return "\(Int(percent.rounded()))%"
    }

    /// Values persisted before percent storage used patch voltage (~2.0–3.2 V).
    static func migrateStoredBatteryLevel(_ stored: Double) -> Double {
        guard stored > 0, stored <= 3.5 else { return stored }
        return batteryPercent(fromPatchVoltage: stored)
    }

    public var sessionToken = Data()
    public var previousPatch: PreviousPatch?
    public var swVersion: String = ""
    public var deviceType: UInt8 = 0
    /// Az utolsó sikeres `CmdTimeSet` ideje. Akku-kímélés: a TimeSet NEM fut minden
    /// syncnél (AAPS sem teszi), csak ha tényleg kell — lásd `lastTimeSetGMTOffset`.
    public var lastTimeSetAt: Date?
    /// A legutóbbi TimeSet-kor érvényes GMT-eltolás (másodperc). Ha ez megváltozik
    /// (időzóna-/DST-váltás), a következő syncnél újra elküldjük a CmdTimeSet-et.
    public var lastTimeSetGMTOffset: Int?

    public var patchActivatedAt: Date? {
        get { activatedAt }
        set { activatedAt = newValue }
    }

    public var pumpSN: Data {
        get {
            guard !serialNumber.isEmpty else { return Data() }
            if serialNumber.count == 6 {
                return Data(serialNumber.utf8)
            }
            return Data(hex: serialNumber) ?? Data(serialNumber.utf8)
        }
        set {
            serialNumber = newValue.hexEncodedString().uppercased()
        }
    }

    public var pumpTime: Date { lastSync }
    public var pumpTimeSyncedAt: Date { lastSync }

    public var patchGracePeriodFrom: Date? {
        guard let patchActivatedAt else { return nil }
        return patchActivatedAt.addingTimeInterval(expiryMode.lifespan)
    }

    public var patchExpiresAt: Date? {
        guard let patchActivatedAt else { return nil }
        return patchActivatedAt.addingTimeInterval(expiryMode.lifespan + expiryMode.gracePeriod)
    }

    public func shouldShowTimeWarning() -> Bool { false }

    public func normalizeDashboardStateIfNeeded() {
        guard isOnboarded, pumpState == .none, !deviceToken.isEmpty else { return }
        pumpState = .active
        if activatedAt == nil {
            activatedAt = lastSync == Date.distantPast ? Date.now : lastSync
        }
        if patchId.isEmpty, !serialNumber.isEmpty {
            patchId = Data(serialNumber.utf8)
        }
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        // Loop-facing suspend only via isSuspended (manual suspend). Physical pump STOP
        // during auto temp-0 must not surface as .suspended — see handoff enactTempBasal fix.
        if isSuspended {
            return .suspended(basalDose.startDate)
        }
        switch basalDose.type {
        case .tempBasal:
            return .tempBasal(basalDose.toDoseEntry())
        case .suspend:
            return .suspended(basalDose.startDate)
        default:
            return .active(basalDose.startDate)
        }
    }

    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)
        return basalSchedule.entries.last(where: { TimeInterval($0.startTimeSeconds) < nowTimeInterval })?.rate ?? 0
    }

    public var model: String { "Equil Patch" }

    public var pumpName: String { "Equil Patch Pump" }

    public var reservoirCapacity: Double { 200 }

    public var debugDescription: String {
        [
            "## EquilPumpState - \(Date.now)",
            "* isOnboarded: \(isOnboarded)",
            "* serialNumber: \(serialNumber)",
            "* deviceToken: \(deviceToken.prefix(8))…",
            "* activationProgress: \(activationProgress.rawValue)",
            "* runMode: \(runMode.rawValue)",
            "* reservoir: \(reservoir) U",
            "* battery: \(Self.displayBatteryText(for: battery))",
            "* lastSync: \(lastSync)",
            "* firmwareVersion: \(firmwareVersion)",
            "* insulinType: \(String(describing: insulinType))"
        ].joined(separator: "\n")
    }

    static func makeBasalSchedule(from items: [LoopKit.RepeatingScheduleValue<Double>]) -> BasalSchedule {
        var rates = [Double](repeating: 0, count: 24)
        let sorted = items.sorted { $0.startTime < $1.startTime }
        for hour in 0 ..< 24 {
            let seconds = hour * 3600
            rates[hour] = sorted.last(where: { $0.startTime <= TimeInterval(seconds) })?.value ?? 0
        }
        return BasalSchedule.fromHourlyRates(rates)
    }

    private static func encodeBasalSchedule(_ schedule: BasalSchedule) -> [[String: Any]] {
        schedule.entries.map { ["rate": $0.rate, "startTimeSeconds": $0.startTimeSeconds] }
    }

    private static func decodePersistedData(hex: String?, legacyData: Data?) -> Data {
        if let legacyData, !legacyData.isEmpty {
            return legacyData
        }
        guard let hex, !hex.isEmpty else {
            return Data()
        }
        if let decoded = Data(hex: hex) {
            return decoded
        }
        return Data(hex.utf8)
    }

    private static func migrateMedtrumAlarmSetting(_ raw: UInt8) -> Int {
        switch AlarmSettings(rawValue: raw) {
        case .LightAndVibrate,
             .VibrateOnly:
            return AlarmMode.shake.rawValue
        case .LightOnly,
             .None:
            return AlarmMode.mute.rawValue
        case .LightVibrateAndBeep,
             .VibrateAndBeep:
            return AlarmMode.toneAndShake.rawValue
        default:
            return AlarmMode.tone.rawValue
        }
    }

    private static func decodeBasalSchedule(_ raw: [[String: Any]]) -> BasalSchedule {
        let entries = raw.compactMap { item -> BasalScheduleEntry? in
            guard let rate = item["rate"] as? Double,
                  let start = item["startTimeSeconds"] as? Int else { return nil }
            return BasalScheduleEntry(rate: rate, startTimeSeconds: start)
        }
        guard !entries.isEmpty else {
            return BasalSchedule.fromHourlyRates(Array(repeating: 0, count: 24))
        }
        return BasalSchedule(entries: entries)
    }
}
