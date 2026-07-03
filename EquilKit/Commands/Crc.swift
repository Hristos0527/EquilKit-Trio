import Foundation

enum Crc {
    /// Crc.crc8Maxim — egyetlen byte eredmény (0...255).
    /// AAPS: wCPoly = 0x8C (Integer.reverse(0x31) >>> 24), init 0x00.
    static func crc8Maxim(_ source: [UInt8]) -> Int {
        var wCRCin = 0x00
        let wCPoly = 0x8C
        for b in source {
            wCRCin ^= Int(b) & 0xFF
            for _ in 0 ..< 8 {
                if (wCRCin & 0x01) != 0 {
                    wCRCin >>= 1
                    wCRCin ^= wCPoly
                } else {
                    wCRCin >>= 1
                }
            }
        }
        wCRCin ^= 0x00
        return wCRCin
    }

    static func crc8Maxim(_ source: Data) -> Int {
        crc8Maxim([UInt8](source))
    }

    /// Crc.getCRC — CRC-16/MODBUS, 2 byte.
    /// FONTOS: az AAPS a crc int-et nagy-endián UPPERCASE hex stringgé alakítja,
    /// 4 karakterre bal-paddingolja, majd hexStringToBytes-szal bytes-szá.
    /// Tehát az eredmény [hi, lo] sorrendű (big-endian a hex stringben).
    static func getCRC(_ bytes: [UInt8]) -> [UInt8] {
        var crc = 0x0000_FFFF
        let polynomial = 0x0000_A001
        for b in bytes {
            crc ^= Int(b) & 0x0000_00FF
            for _ in 0 ..< 8 {
                if (crc & 0x0000_0001) != 0 {
                    crc >>= 1
                    crc ^= polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        // Integer.toHexString(crc).uppercase() — nincs vezető nulla
        var result = String(crc, radix: 16, uppercase: true)
        if result.count != 4 {
            // AAPS: StringBuffer("0000").replace(4 - len, 4, result)
            // = bal-padding nullákkal 4 karakterre (a legalsó 4 hex számjegy)
            let padded = String(repeating: "0", count: max(0, 4 - result.count)) + result
            result = String(padded.suffix(4))
        }
        return EquilUtils.hexStringToBytes(result)
    }

    static func getCRC(_ data: Data) -> [UInt8] {
        getCRC([UInt8](data))
    }
}
