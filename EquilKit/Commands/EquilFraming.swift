import Foundation

enum EquilFraming {
    /// reqIndex bit7 = 0 (folytatódó csomag).  BaseCmd.toNewStart
    static func toNewStart(_ number: UInt8) -> UInt8 {
        number & ~(1 << 7)
    }

    /// reqIndex bit7 = 1 (záró csomag).  BaseCmd.toNewEndConf
    static func toNewEndConf(_ number: UInt8) -> UInt8 {
        number | (1 << 7)
    }

    /// BaseCmd.up1 — felfelé kerekítés (RoundingMode.UP).
    static func up1(_ value: Double) -> Int {
        Int(ceil(value))
    }

    /// BaseCmd.responseCmd byte-azonos portja.
    /// - port: pl. "0F0F0000" (DEFAULT_PORT + "0000") vagy "0D0D0000" (pair)
    /// - tag/iv/ciphertext: az AESUtil.aesEncrypt hex kimenete
    /// - reqIndex: a BaseCmd.reqIndex aktuális értéke
    /// Visszaad: BLE csomagok listája ([[UInt8]]).
    static func responseCmd(
        port: String,
        tag: String,
        iv: String,
        ciphertext: String,
        reqIndex: Int
    ) -> [[UInt8]] {
        let allHex = port + tag + iv + ciphertext
        let allByte = EquilUtils.hexStringToBytes(allHex)
        let crc1 = Crc.getCRC(allByte) // 2 byte: [hi, lo]

        let n = allByte.count
        let index = ((n - 8) % 10 == 0) ? 1 : 2
        // KRITIKUS: a Kotlin forrásban ((allByte.size - 8) / 10) EGÉSZ osztás (Int/Int),
        // és csak UTÁNA .toDouble(). NEM lebegőpontos osztás!
        // up1((( n - 8 ) / 10).toDouble()) + index
        let maxLen = up1(Double((n - 8) / 10)) + index

        var packets: [[UInt8]] = []
        var byteIndex = 0
        var lastLen = 0

        for i in 0 ..< maxLen {
            var buffer: [UInt8] = []
            buffer.append(0x00)
            buffer.append(0x00)
            if i == maxLen - 1 {
                buffer.append(UInt8((6 + lastLen) & 0xFF))
                buffer.append(UInt8((10 * i) & 0xFF))
                buffer.append(toNewEndConf(UInt8(reqIndex & 0xFF)))
            } else {
                buffer.append(0x10)
                buffer.append(UInt8((10 * i) & 0xFF))
                buffer.append(toNewStart(UInt8(reqIndex & 0xFF)))
            }
            // crc8Maxim az első 5 byte-ra
            let crcArray = Array(buffer[0 ..< 5])
            buffer.append(UInt8(Crc.crc8Maxim(crcArray) & 0xFF))

            if i == 0 {
                // 4 payload byte
                for _ in 0 ..< 4 { buffer.append(allByte[byteIndex])
                    byteIndex += 1 }
                // 16-bites payload CRC FORDÍTVA: low (crc1[1]) majd high (crc1[0])
                buffer.append(crc1[1])
                buffer.append(crc1[0])
                // további 4 payload byte
                for _ in 0 ..< 4 { buffer.append(allByte[byteIndex])
                    byteIndex += 1 }
            } else {
                let take = lastLen < 10 ? lastLen : 10
                for _ in 0 ..< take { buffer.append(allByte[byteIndex])
                    byteIndex += 1 }
            }
            lastLen = allByte.count - byteIndex
            packets.append(buffer)
        }
        return packets
    }
}
