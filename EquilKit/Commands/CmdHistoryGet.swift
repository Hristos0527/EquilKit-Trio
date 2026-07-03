import Foundation

final class CmdHistoryGet: EquilBaseSetting {
    let currentIndex: Int

    private(set) var battery: Int = 0
    private(set) var medicine: Int = 0
    private(set) var rate: Int = 0
    private(set) var largeRate: String = ""
    private(set) var timestamp: Int64 = 0
    private(set) var historyIndex: Int = 0
    private(set) var eventType: Int = 0
    private(set) var level: Int = 0
    private(set) var parm: Int = 0
    private(set) var resultIndex: Int = 0

    init(
        currentIndex: Int,
        createTime: Int64,
        equilDevice: String,
        equilPassword: String
    ) {
        self.currentIndex = currentIndex
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "History query (CmdHistoryGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x01]
        let data3 = EquilUtils.intToBytes(currentIndex)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x01, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count >= 24 else { return }
        let year = Int(data[6]) & 0xFF
        let month = Int(data[7]) & 0xFF
        let day = Int(data[8]) & 0xFF
        let hour = Int(data[9]) & 0xFF
        let minute = Int(data[10]) & 0xFF
        let second = Int(data[11]) & 0xFF
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        timestamp = Int64((Calendar.current.date(from: components) ?? Date()).timeIntervalSince1970 * 1000)
        battery = Int(data[12]) & 0xFF
        medicine = Int(data[13]) & 0xFF
        rate = EquilUtils.bytesToInt(data[15], data[14])
        largeRate = EquilUtils.bytesToHex([data[16], data[17]])
        historyIndex = EquilUtils.bytesToInt(data[19], data[18])
        eventType = Int(data[21]) & 0xFF
        level = Int(data[22]) & 0xFF
        parm = Int(data[23]) & 0xFF
        resultIndex = historyIndex
        cmdSuccess = true
    }
}
