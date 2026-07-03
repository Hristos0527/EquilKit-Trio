import Foundation

final class CmdStepSet: EquilBaseSetting {
    let sendConfig: Bool
    let step: Int

    init(
        sendConfig: Bool,
        step: Int,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.sendConfig = sendConfig
        self.step = step
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "Pin move (CmdStepSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x07]
        let data3 = EquilUtils.intToBytes(step)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x07, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }

    override func decodeConfirmStep() -> EquilResponse? {
        do {
            let model = decodeModel()
            runCode = model.code
            guard let runPwd = runPwd else { return nil }
            let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
            decodeConfirmData(EquilUtils.hexStringToBytes(content))
            guard sendConfig, let nextData = getNextData() else { return nil }
            let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(runPwd), data: nextData)
            isEnd = true
            response = EquilResponse(createTime: createTime)
            return responseCmd(model2, port: port + (runCode ?? ""))
        } catch {
            response = EquilResponse(createTime: createTime)
            return nil
        }
    }
}
