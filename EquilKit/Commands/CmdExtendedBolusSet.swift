import Foundation

final class CmdExtendedBolusSet: EquilBaseSetting {
    let insulin: Double
    let durationInMinutes: Int
    let cancel: Bool
    var step: Int = 0
    var pumpTime: Int = 0

    init(
        insulin: Double,
        durationInMinutes: Int,
        cancel: Bool,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.insulin = insulin
        self.durationInMinutes = durationInMinutes
        self.cancel = cancel
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        if insulin != 0.0 {
            step = Int(insulin / 0.05 * 8)
            pumpTime = durationInMinutes * 60
        }
    }

    override var commandLabel: String { "Extended bolus (CmdExtendedBolusSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x03]
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(pumpTime)
        let zero = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, zero, zero, data3, data4)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x03, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
