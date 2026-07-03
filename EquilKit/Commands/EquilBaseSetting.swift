import Foundation

class EquilBaseSetting: EquilBaseCmd {
    // MARK: - getReqData (BaseSetting.getReqData)

    /// index(4LE) ++ device SN bytes.  pumpReqIndex++.
    func getReqData() -> [UInt8] {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let tzm = EquilUtils.hexStringToBytes(getEquilDevices())
        let data = EquilUtils.concat(indexByte, tzm)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // MARK: - 1. üzenet: getEquilResponse (BaseSetting.getEquilResponse)

    func getEquilResponse() throws -> EquilResponse {
        config = false
        isEnd = false
        response = EquilResponse(createTime: createTime)
        let pwd = EquilUtils.hexStringToBytes(getEquilPassWord())
        let data = getReqData()
        let model = try AESUtil.aesEncrypt(key: pwd, data: data)
        return responseCmd(model, port: EquilBaseCmd.DEFAULT_PORT + "0000")
    }

    // MARK: - 2. üzenet: decode (BaseSetting.decode)

    /// A pump válaszának feldolgozása után küldi a tényleges payloadot (getFirstData).
    /// A `respModel` a beérkezett csomagokból decodeModel()-lel állítható elő.
    func decode() throws -> EquilResponse {
        let reqModel = decodeModel()
        let pwd = EquilUtils.hexStringToBytes(getEquilPassWord())
        let content = try AESUtil.decrypt(reqModel, key: pwd)
        // content HEX string; substring(8) = az első 4 byte (8 hex char) levágása
        let pwd2 = String(content.dropFirst(8))
        runPwd = pwd2
        guard let firstData = getFirstData() else {
            throw EquilError.invalidState("getFirstData nil")
        }
        let model = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(pwd2), data: firstData)
        runCode = reqModel.code
        return responseCmd(model, port: port + (runCode ?? ""))
    }

    // MARK: - EquilCommandDriving felülírás (minden setting-parancs az első üzenettel indul)

    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - getNextEquilResponse (BaseSetting.getNextEquilResponse)

    func getNextEquilResponse() throws -> EquilResponse {
        config = true
        isEnd = false
        response = EquilResponse(createTime: createTime)
        guard let firstData = getFirstData() else {
            throw EquilError.invalidState("getFirstData nil")
        }
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let model = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(runPwd), data: firstData)
        return responseCmd(model, port: port + (runCode ?? ""))
    }

    // MARK: - 3. üzenet: decodeConfirm (BaseSetting.decodeConfirm)

    func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        guard let nextData = getNextData() else {
            throw EquilError.invalidState("getNextData nil")
        }
        let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(runPwd), data: nextData)
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    // MARK: - Absztrakt (alosztály felülírja)

    func getFirstData() -> [UInt8]? { nil }
    func getNextData() -> [UInt8]? { nil }
    func decodeConfirmData(_: [UInt8]) {}

    // MARK: - Beérkező állapotgép bekötése (EquilBaseCmd.decodeEquilPacket hívja)

    /// 1. fázis lezárása: a pump válaszából runPwd, majd getFirstData payload.
    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }

    /// 2. fázis lezárása: decodeConfirmData (siker), majd getNextData.
    override func decodeConfirmStep() -> EquilResponse? {
        do { return try decodeConfirm() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }
}
