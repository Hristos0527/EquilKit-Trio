import Foundation

final class CmdInsulinGet: EquilBaseSetting {
    private(set) var insulin: Int = 0

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "Insulin query (CmdInsulinGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x07]
        let data = EquilUtils.concat(indexByte, data2)
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

    override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count > 6 else { return }
        insulin = Int(data[6]) & 0xFF
        cmdSuccess = true
    }
}
