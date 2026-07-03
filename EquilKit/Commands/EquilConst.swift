import Foundation

enum EquilConst {
    /// Command timeout (ms).
    static let EQUIL_CMD_TIME_OUT: Int64 = 300_000
    /// Minimum pause between BLE writes (ms).
    static let EQUIL_BLE_WRITE_TIME_OUT: Int64 = 20
    /// Wait between commands in the pairing flow (ms).
    static let EQUIL_BLE_NEXT_CMD: Int64 = 500
    /// Supported firmware threshold. RELAXED: any firmware above 1.0 is supported
    /// for ALL serial-number prefixes (no SN-prefix rejection during pairing).
    /// Only invalid (< 1.0 or 0/missing) firmware is rejected.
    /// (Previously 5.3, which excluded 0/1/3/A/D prefix pumps.)
    static let EQUIL_SUPPORT_LEVEL: Float = 1.0
    /// Default bolus threshold step.
    static let EQUIL_BOLUS_THRESHOLD_STEP: Int = 1600
    /// Default basal threshold step.
    static let EQUIL_BASAL_THRESHOLD_STEP: Int = 240
    static let EQUIL_STEP_MAX: Int = 32000
    /// Size of one fill step. 160 → 320: the pump accepts it (4-byte field, 320 ≪ EQUIL_STEP_MAX
    /// 32000), so half as many BLE commands for the same priming → ~half as many steps.
    /// 320 steps ≈ ~2 U. Resistance check on EVERY step (resistanceCheckEvery=1) →
    /// a fill crossing the threshold has worst-case overshoot of ~1 step ≈ ~2 U between
    /// resistance detection and stop (instead of the every-2 ~4 U window).
    static let EQUIL_STEP_FILL: Int = 320
    /// Size of one manual "1 step" prime button press (~0.5 U). Auto fill stays at 320.
    static let EQUIL_STEP_MANUAL: Int = 80
    static let EQUIL_STEP_AIR: Int = 120

    /// AAPS `EquilManager.OLD_PUMP_SERIAL_PREFIXES` + `getResistanceThreshold()`
    static let oldPumpSerialPrefixes: Set<Character> = ["0", "1", "3", "A", "D"]

    static func resistanceThreshold(for serialNumber: String) -> Int {
        let suffix = serialNumber.components(separatedBy: " - ").last ?? serialNumber
        let first = suffix.uppercased().first
        return first.map { oldPumpSerialPrefixes.contains($0) ? 500 : 220 } ?? 220
    }
}
