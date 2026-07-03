import Foundation

final class CmdDevicesGet: EquilBaseSetting {
    private(set) var firmwareVersion: String = ""
    private(set) var deviceValue: Int = 0

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0000"
    }

    override var commandLabel: String { "Device query (CmdDevicesGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x00]
        let data = EquilUtils.concat(indexByte, data2)
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

    override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count >= 20 else { return }
        deviceValue = EquilUtils.bytesToInt(data[7], data[6])
        firmwareVersion = "\(Int(data[18])).\(Int(data[19]))"
        cmdSuccess = true
    }
}
