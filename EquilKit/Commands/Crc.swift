import Foundation

enum Crc {
    /// Crc.crc8Maxim — single-byte result (0...255).
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

    /// Crc.getCRC — CRC-16/MODBUS, 2 bytes.
    /// IMPORTANT: AAPS converts the crc int to big-endian UPPERCASE hex string,
    /// left-pads to 4 characters, then to bytes via hexStringToBytes.
    /// So the result is [hi, lo] order (big-endian in the hex string).
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
        // Integer.toHexString(crc).uppercase() — no leading zero
        var result = String(crc, radix: 16, uppercase: true)
        if result.count != 4 {
            // AAPS: StringBuffer("0000").replace(4 - len, 4, result)
            // = left-pad with zeros to 4 characters (lowest 4 hex digits)
            let padded = String(repeating: "0", count: max(0, 4 - result.count)) + result
            result = String(padded.suffix(4))
        }
        return EquilUtils.hexStringToBytes(result)
    }

    static func getCRC(_ data: Data) -> [UInt8] {
        getCRC([UInt8](data))
    }
}
