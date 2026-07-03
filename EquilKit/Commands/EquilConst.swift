import Foundation

enum EquilConst {
    /// Parancs timeout (ms).
    static let EQUIL_CMD_TIME_OUT: Int64 = 300_000
    /// BLE írások közti minimális szünet (ms).
    static let EQUIL_BLE_WRITE_TIME_OUT: Int64 = 20
    /// Két parancs közti várakozás a párosítási flow-ban (ms).
    static let EQUIL_BLE_NEXT_CMD: Int64 = 500
    /// Támogatott firmware-küszöb. LAZÍTVA: minden 1.0 FELETTI firmware támogatott,
    /// MINDEN sorozatszám-prefixre (nincs SN-prefix alapú elutasítás a párosításnál).
    /// Csak az érvénytelen (< 1.0 vagy 0/hiányzó) firmware-t utasítjuk el.
    /// (Korábban 5.3 volt, ami a 0/1/3/A/D prefixű pumpákat kizárta.)
    static let EQUIL_SUPPORT_LEVEL: Float = 1.0
    /// Alapértelmezett bólus-küszöb lépés.
    static let EQUIL_BOLUS_THRESHOLD_STEP: Int = 1600
    /// Alapértelmezett basal-küszöb lépés.
    static let EQUIL_BASAL_THRESHOLD_STEP: Int = 240
    static let EQUIL_STEP_MAX: Int = 32000
    /// Egy fill-lépés mérete. 160 → 320: a pumpa elfogadja (4 byte-os mező, 320 ≪ EQUIL_STEP_MAX
    /// 32000), így feleannyi BLE-parancs kell ugyanannyi priminghez → ~feleannyi lépés.
    /// 320 lépés ≈ ~2 U. Resistance-ellenőrzés MINDEN lépésnél (resistanceCheckEvery=1) →
    /// a küszöböt átlépő fill a worst-case overshoot, azaz ~1 lépés ≈ ~2 U a resistance-detektálás
    /// és a leállás között (az every-2 ~4 U ablaka helyett).
    static let EQUIL_STEP_FILL: Int = 320
    /// Egy manuális „1 lépés” prime gombnyomás mérete (~0,5 U). Az auto fill 320 marad.
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
