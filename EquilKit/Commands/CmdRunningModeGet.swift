import Foundation

final class CmdRunningModeGet: EquilBaseSetting {
    private(set) var runMode: Int = -1

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "Running mode query (CmdRunningModeGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x00]
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
        guard data.count > 6 else { return }
        runMode = Int(data[6]) & 0xFF
        cmdSuccess = true
    }
}
