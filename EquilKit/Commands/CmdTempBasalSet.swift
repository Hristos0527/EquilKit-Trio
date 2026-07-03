import Foundation

final class CmdTempBasalSet: EquilBaseSetting {
    let insulin: Double
    let duration: Int
    var cancel: Bool = false
    var step: Int = 0
    var pumpTime: Int = 0

    init(
        insulin: Double,
        duration: Int,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.insulin = insulin
        self.duration = duration
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        if insulin != 0.0 {
            step = Int(insulin / 0.05 * 8) / 2
        }
        pumpTime = duration * 60
    }

    override var commandLabel: String { "Temp basal (CmdTempBasalSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x04]
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(pumpTime)
        let data = EquilUtils.concat(indexByte, data2, data3, data4)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x04, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
