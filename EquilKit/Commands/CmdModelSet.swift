import Foundation

final class CmdModelSet: EquilBaseSetting {
    let mode: Int

    init(
        mode: Int,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.mode = mode
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    func resolvedRunMode() -> RunMode {
        switch mode {
        case 0: return .suspend
        case 1,
             2: return .run
        default: return .suspend
        }
    }

    override var commandLabel: String { "Run mode (CmdModelSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x00]
        let data3 = EquilUtils.intToBytes(mode)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x00, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
