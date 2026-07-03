import Foundation

enum EquilUtils {
    /// Utils.generateRandomPassword — cryptographically secure random bytes.
    static func generateRandomPassword(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes
    }

    /// Utils.intToBytes — 4 byte LITTLE-ENDIAN (src[0] = LSB).
    static func intToBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF)
        ]
    }

    /// Utils.bytes2Int — 4 byte little-endian → Int.
    static func bytes2Int(_ bytes: [UInt8]) -> Int {
        let int1 = Int(bytes[0]) & 0xFF
        let int2 = (Int(bytes[1]) & 0xFF) << 8
        let int3 = (Int(bytes[2]) & 0xFF) << 16
        let int4 = (Int(bytes[3]) & 0xFF) << 24
        return int1 | int2 | int3 | int4
    }

    /// Utils.intToTwoBytes — 2 byte little-endian.
    static func intToTwoBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// Utils.bytesToInt — high/low byte, 0x8000 wrap.
    static func bytesToInt(_ highByte: UInt8, _ lowByte: UInt8) -> Int {
        let highValue = (Int(highByte) & 0xFF) << 8
        let lowValue = Int(lowByte) & 0xFF
        let value = highValue | lowValue
        if value >= 0x8000 {
            return value - 0x8000
        }
        return value
    }

    /// Utils.decodeSpeedToUH(Double) -> Int — basal rate to steps.
    /// AAPS: BigDecimal(i) / 0.00625 (RoundingMode down, because toInt truncates).
    static func decodeSpeedToUH(_ i: Double) -> Int {
        // AAPS: BigDecimal(i).divide(0.00625).toInt()  →  TRUNCATE toward zero.
        // 0.00625 = 1/160, so i/0.00625 = i*160. BigDecimal.toInt() TRUNCATES
        // (does not round), so we truncate here too (RoundingMode.DOWN / toward zero).
        var exact = (Decimal(i) / Decimal(string: "0.00625")!)
        var truncated = Decimal()
        NSDecimalRound(&truncated, &exact, 0, .down)
        return NSDecimalNumber(decimal: truncated).intValue
    }

    /// Utils.basalToByteArray — BIG-endian 2 byte (result[0]=hi).
    static func basalToByteArray(_ v: Double) -> [UInt8] {
        let value = decodeSpeedToUH(v)
        return [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Utils.basalToByteArray2 — LITTLE-endian 2 byte (result[0]=lo).
    static func basalToByteArray2(_ v: Double) -> [UInt8] {
        let value = decodeSpeedToUH(v)
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// Utils.hexStringToBytes — handles lowercase (uppercases).
    static func hexStringToBytes(_ hex: String) -> [UInt8] {
        let hexString = hex.uppercased()
        let chars = Array(hexString)
        let length = chars.count / 2
        var d = [UInt8](repeating: 0, count: length)
        let lut = "0123456789ABCDEF"
        func charToByte(_ c: Character) -> Int {
            lut.distance(of: c) ?? 0
        }
        for i in 0 ..< length {
            let pos = i * 2
            let hi = charToByte(chars[pos])
            let lo = charToByte(chars[pos + 1])
            d[i] = UInt8((hi << 4) | lo)
        }
        return d
    }

    /// Utils.concat — concatenate byte arrays.
    static func concat(_ arrays: [UInt8]...) -> [UInt8] {
        var result: [UInt8] = []
        for a in arrays { result.append(contentsOf: a) }
        return result
    }

    /// Utils.bytesToHex — uppercase hex string.
    static func bytesToHex(_ bytes: [UInt8]) -> String {
        let hexArray = Array("0123456789ABCDEF")
        var chars = [Character](repeating: "0", count: bytes.count * 2)
        for (j, byte) in bytes.enumerated() {
            let v = Int(byte) & 0xFF
            chars[j * 2] = hexArray[v >> 4]
            chars[j * 2 + 1] = hexArray[v & 0x0F]
        }
        return String(chars)
    }

    static func bytesToHex(_ data: Data) -> String {
        bytesToHex([UInt8](data))
    }
}

private extension String {
    /// Index of a character in the string (for charToByte LUT).
    func distance(of character: Character) -> Int? {
        guard let idx = firstIndex(of: character) else { return nil }
        return distance(from: startIndex, to: idx)
    }
}
