import Foundation

final class CmdSettingSet: EquilBaseSetting {
    let bolusThresholdStep: Int
    let basalThresholdStep: Int

    init(
        maxBolus: Double,
        maxBasal: Double,
        equilDevice: String,
        equilPassword: String,
        createTime: Int64
    ) {
        bolusThresholdStep = EquilUtils.decodeSpeedToUH(maxBolus)
        basalThresholdStep = EquilUtils.decodeSpeedToUH(maxBasal)
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // BaseSetting DEFAULT_PORT (0F0F) — CmdSettingSet does not override the port.
    }

    override var commandLabel: String { "Settings (CmdSettingSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let equilCmd: [UInt8] = [0x01, 0x05]
        let useTime = EquilUtils.intToBytes(0)
        let autoCloseTime = EquilUtils.intToBytes(0)
        let lowAlarmByte = EquilUtils.intToTwoBytes(1600)
        let fastBolus = EquilUtils.intToTwoBytes(0)
        let occlusion = EquilUtils.intToTwoBytes(2800)
        let insulinUnit = EquilUtils.intToTwoBytes(8)
        let basalThreshold = EquilUtils.intToTwoBytes(basalThresholdStep)
        let bolusThreshold = EquilUtils.intToTwoBytes(bolusThresholdStep)
        var data = EquilUtils.concat(indexByte, equilCmd)
        data = EquilUtils.concat(data, useTime)
        data = EquilUtils.concat(data, autoCloseTime)
        data = EquilUtils.concat(data, lowAlarmByte)
        data = EquilUtils.concat(data, fastBolus)
        data = EquilUtils.concat(data, occlusion)
        data = EquilUtils.concat(data, insulinUnit)
        data = EquilUtils.concat(data, basalThreshold)
        data = EquilUtils.concat(data, bolusThreshold)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x05, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_: [UInt8]) {
        cmdSuccess = true
    }
}
