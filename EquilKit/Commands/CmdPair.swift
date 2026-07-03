import CryptoKit
import Foundation

final class CmdPair: EquilBaseCmd {
    static let ERROR_PWD = String(repeating: "0", count: 64)

    let pairPassword: String // a felhasználó által megadott jelszó (pl. "0000")
    let address: String // BLE MAC cím (AAPS CmdPair 2. paramétere)
    var sn: String
    var randomPassword: [UInt8]?

    /// Az újonnan kialkudott device/password — a hívó ezt menti el a sikeres pároláskor.
    var newDevice: String?
    var newPassword: String?

    init(
        name: String,
        address: String,
        pairPassword: String,
        createTime: Int64
    ) {
        self.pairPassword = pairPassword
        self.address = address
        var s = name.replacingOccurrences(of: "Equil - ", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        // convertString: minden karakter elé "0"
        var conv = ""
        for ch in s { conv += "0"
            conv.append(ch) }
        sn = conv
        // a párosításnál még nincs tárolt device/password
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        port = "0E0E"
    }

    // MARK: - 1. üzenet: getEquilResponse

    func getEquilResponse() throws -> EquilResponse {
        response = EquilResponse(createTime: createTime)
        // key = SHA-256(hexBytes(sn))
        let snBytes = EquilUtils.hexStringToBytes(sn)
        let digest = SHA256.hash(data: Data(snBytes))
        let key = [UInt8](digest)

        let equilPassword = AESUtil.getEquilPassWord(pairPassword) // 32 byte
        let rnd = EquilUtils.generateRandomPassword(32)
        randomPassword = rnd
        let data = EquilUtils.concat(equilPassword, rnd)
        let model = try AESUtil.aesEncrypt(key: key, data: data)
        return responseCmd(model, port: "0D0D0000")
    }

    func getNextEquilResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - EquilCommandDriving felülírás

    override var commandLabel: String { "Pairing (CmdPair)" }
    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - 2. üzenet: decode

    func decode() throws -> EquilResponse? {
        let model = decodeModel()
        guard let keyBytes = randomPassword else { return nil }
        let content = try AESUtil.decrypt(model, key: keyBytes) // 128 hex char
        let pwd1 = String(content.prefix(64)) // device
        let pwd2 = String(content.dropFirst(64)) // password
        if CmdPair.ERROR_PWD == pwd1, CmdPair.ERROR_PWD == pwd2 {
            // AAPS: cmdSuccess=true, enacted=false — a pump hibát/elutasítást jelez
            cmdSuccess = true
            enacted = false
            return nil
        }
        newDevice = pwd1
        newPassword = pwd2
        runPwd = pwd2
        let data1 = EquilUtils.hexStringToBytes(pwd1)
        let data = EquilUtils.concat(data1, keyBytes)
        let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(pwd2), data: data)
        runCode = model.code
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    // MARK: - 3. üzenet: decodeConfirm

    func decodeConfirm() -> EquilResponse? {
        cmdSuccess = true
        return nil
    }

    // MARK: - Beérkező állapotgép bekötése (EquilBaseCmd.decodeEquilPacket hívja)

    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }

    override func decodeConfirmStep() -> EquilResponse? {
        decodeConfirm()
    }
}
