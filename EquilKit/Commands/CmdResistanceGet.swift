import Foundation

final class CmdResistanceGet: EquilBaseSetting {
    let resistanceThreshold: Int
    private(set) var resistance: Int = 0

    init(
        resistanceThreshold: Int,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.resistanceThreshold = resistanceThreshold
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "1515"
    }

    override var commandLabel: String { "Resistance query (CmdResistanceGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x02]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x02, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count > 7 else { return }
        resistance = EquilUtils.bytesToInt(data[7], data[6])
        cmdSuccess = true
        enacted = resistance >= resistanceThreshold
    }

    override func decodeConfirmStep() -> EquilResponse? {
        do {
            let model = decodeModel()
            runCode = model.code
            guard let runPwd = runPwd else { return nil }
            let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
            decodeConfirmData(EquilUtils.hexStringToBytes(content))
            isEnd = true
            response = EquilResponse(createTime: createTime)
            return nil
        } catch {
            response = EquilResponse(createTime: createTime)
            return nil
        }
    }
}
