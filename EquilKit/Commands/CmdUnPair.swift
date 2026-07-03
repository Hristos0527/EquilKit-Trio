import CryptoKit
import Foundation

final class CmdUnPair: EquilBaseCmd {
    let unpairPassword: String
    var sn: String
    var randomPassword: [UInt8]?

    init(
        name: String,
        password: String,
        createTime: Int64
    ) {
        unpairPassword = password
        var s = name.replacingOccurrences(of: "Equil - ", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        var conv = ""
        for ch in s { conv += "0"
            conv.append(ch) }
        sn = conv
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        port = "0E0E"
    }

    func getEquilResponse() throws -> EquilResponse {
        response = EquilResponse(createTime: createTime)
        let snBytes = EquilUtils.hexStringToBytes(sn)
        let digest = SHA256.hash(data: Data(snBytes))
        let key = [UInt8](digest)

        let equilPassword = AESUtil.getEquilPassWord(unpairPassword)
        let rnd = EquilUtils.generateRandomPassword(32)
        randomPassword = rnd
        let data = EquilUtils.concat(equilPassword, rnd)
        let model = try AESUtil.aesEncrypt(key: key, data: data)
        return responseCmd(model, port: "0D0D0000")
    }

    func getNextEquilResponse() throws -> EquilResponse { try getEquilResponse() }

    override var commandLabel: String { "Unpair (CmdUnPair)" }
    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    func decode() throws -> EquilResponse? {
        let model = decodeModel()
        guard let keyBytes = randomPassword else { return nil }
        let content = try AESUtil.decrypt(model, key: keyBytes)
        let pwd1 = String(content.prefix(64))
        let pwd2 = String(content.dropFirst(64))
        runPwd = pwd2
        let data1 = EquilUtils.hexStringToBytes(pwd1)
        let data = EquilUtils.concat(data1, keyBytes)
        let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(pwd2), data: data)
        runCode = model.code
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    func decodeConfirm() -> EquilResponse? {
        cmdSuccess = true
        return nil
    }

    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }

    override func decodeConfirmStep() -> EquilResponse? {
        decodeConfirm()
    }
}
