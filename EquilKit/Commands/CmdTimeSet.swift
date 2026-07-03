import Foundation

final class CmdTimeSet: EquilBaseSetting {
    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "Time set (CmdTimeSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x00]
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = UInt8(truncatingIfNeeded: (components.year ?? 2000) - 2000)
        let month = UInt8(truncatingIfNeeded: components.month ?? 1)
        let day = UInt8(truncatingIfNeeded: components.day ?? 1)
        let hour = UInt8(truncatingIfNeeded: components.hour ?? 0)
        let minute = UInt8(truncatingIfNeeded: components.minute ?? 0)
        let second = UInt8(truncatingIfNeeded: components.second ?? 0)
        let data3: [UInt8] = [year, month, day, hour, minute, second]
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
