import Foundation

final class CmdBasalGet: EquilBaseSetting {
    let hourlyBasalRates: [Double]

    init(
        hourlyBasalRates: [Double],
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.hourlyBasalRates = hourlyBasalRates
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "Basal profile query (CmdBasalGet)" }

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
        var currentBasal = ""
        for i in 0 ..< 24 {
            var value = hourlyBasalRates[i]
            value = value / 2.0
            let bs = EquilUtils.basalToByteArray2(value)
            currentBasal += EquilUtils.bytesToHex(bs)
            currentBasal += EquilUtils.bytesToHex(bs)
        }
        let rspByte = Array(data[6 ..< data.count])
        let rspBasal = EquilUtils.bytesToHex(rspByte)
        cmdSuccess = true
        enacted = currentBasal == rspBasal
    }
}
