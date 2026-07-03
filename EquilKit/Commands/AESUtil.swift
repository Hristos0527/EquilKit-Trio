import CryptoKit
import Foundation

/// AAPS EquilCmdModel equivalent: three hex-string fields of the encrypted packet.
struct EquilCmdModel {
    var code: String?
    var iv: String?
    var tag: String?
    var ciphertext: String?
}

enum AESUtil {
    /// AESUtil.generateAESKeyFromPassword — SHA256(password)[2..18], 16 bytes.
    static func generateAESKeyFromPassword(_ password: String) -> [UInt8] {
        let hash = SHA256.hash(data: Data(password.utf8))
        let hashBytes = [UInt8](hash) // 32 bytes
        return Array(hashBytes[2 ..< 18]) // 16 bytes (offset 2)
    }

    /// AESUtil.getEquilPassWord — defaultKey("Equil") ++ key(password) = 32 bytes.
    static func getEquilPassWord(_ password: String) -> [UInt8] {
        let defaultKey = generateAESKeyFromPassword("Equil")
        return defaultKey + generateAESKeyFromPassword(password)
    }

    /// AESUtil.generateRandomIV — cryptographically secure random IV.
    static func generateRandomIV(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes
    }

    /// AESUtil.aesEncrypt — AES-GCM, output: tag | iv | ciphertext (hex strings).
    /// AAPS splits the last 16 tag bytes from the Java GCM output;
    /// CryptoKit returns ciphertext and tag separately — same byte layout.
    /// Optional fixedIV: deterministic testing (otherwise random 12B).
    static func aesEncrypt(key: [UInt8], data: [UInt8], fixedIV: [UInt8]? = nil) throws -> EquilCmdModel {
        let iv = fixedIV ?? generateRandomIV(12)
        let symmetricKey = SymmetricKey(data: Data(key))
        let nonce = try AES.GCM.Nonce(data: Data(iv))
        let sealed = try AES.GCM.seal(Data(data), using: symmetricKey, nonce: nonce)

        var model = EquilCmdModel()
        model.tag = EquilUtils.bytesToHex([UInt8](sealed.tag))
        model.iv = EquilUtils.bytesToHex(iv)
        model.ciphertext = EquilUtils.bytesToHex([UInt8](sealed.ciphertext))
        return model
    }

    /// AESUtil.decrypt — AES-GCM decryption, result is uppercase hex string.
    static func decrypt(_ model: EquilCmdModel, key: [UInt8]) throws -> String {
        guard let ivHex = model.iv,
              let ctHex = model.ciphertext,
              let tagHex = model.tag
        else {
            throw EquilError.decryptMissingField
        }
        let iv = EquilUtils.hexStringToBytes(ivHex)
        let ciphertext = EquilUtils.hexStringToBytes(ctHex)
        let tag = EquilUtils.hexStringToBytes(tagHex)
        let symmetricKey = SymmetricKey(data: Data(key))
        let nonce = try AES.GCM.Nonce(data: Data(iv))
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        let decrypted = try AES.GCM.open(box, using: symmetricKey)
        return EquilUtils.bytesToHex([UInt8](decrypted))
    }
}

enum EquilError: Error {
    case decryptMissingField
    case notPaired
    case bleWriteFailed
    case bleTimeout
    case responseCrcMismatch
    case invalidState(String)
}
