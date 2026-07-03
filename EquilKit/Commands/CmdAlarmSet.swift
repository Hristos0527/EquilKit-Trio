import Foundation

final class CmdAlarmSet: EquilBaseSetting {
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

    init(
        alarmMode: AlarmMode,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        mode = alarmMode.command
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "Alarm mode (CmdAlarmSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x0B]
        let data3 = EquilUtils.intToBytes(mode)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x0B, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
