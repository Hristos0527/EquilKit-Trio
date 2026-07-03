import Foundation

final class CmdBasalSet: EquilBaseSetting {
    let basalSchedule: BasalSchedule

    init(
        basalSchedule: BasalSchedule,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.basalSchedule = basalSchedule
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "Basal profile (CmdBasalSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x02]
        var profileBytes: [UInt8] = []
        for entry in basalSchedule.entries {
            let value = entry.rate / 2.0
            let bs = EquilUtils.basalToByteArray(value)
            profileBytes.append(bs[1])
            profileBytes.append(bs[0])
            profileBytes.append(bs[1])
            profileBytes.append(bs[0])
        }
        let data = EquilUtils.concat(indexByte, data2, profileBytes)
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

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
