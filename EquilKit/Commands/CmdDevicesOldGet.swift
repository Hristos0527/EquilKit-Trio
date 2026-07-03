import Foundation

final class CmdDevicesOldGet: EquilBaseSetting {
    let address: String
    private(set) var firmwareVersion: Float = 0

    init(address: String, createTime: Int64) {
        self.address = address
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        port = "0E0E"
    }

    // MARK: - 1st message: fixed 14-byte, NO ENCRYPTION

    override func getEquilResponse() throws -> EquilResponse {
        config = false
        isEnd = false
        response = EquilResponse(createTime: createTime)
        var temp = EquilResponse(createTime: createTime)
        let opener: [UInt8] = [
            0x00, 0x00, 0x0E, 0x00, 0x80, 0x78,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x7B, 0x02, 0x00
        ]
        temp.add(opener)
        return temp
    }

    override var commandLabel: String { "Device query (CmdDevicesOldGet)" }
    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - getFirstData / getNextData (nyers byte-ok)

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

    // MARK: - Custom decodeModel (NO tag/iv; ciphertext = raw bytes)

    override func decodeModel() -> EquilCmdModel {
        var model = EquilCmdModel()
        var list: [UInt8] = []
        guard let response = response, !response.send.isEmpty else { return model }
        for (index, bs) in response.send.enumerated() {
            if index == 0 {
                // GUARD (pump swap/pairing race): truncated (stray/leftover) first frame
                // → no out-of-bounds indexing ([10],[11] + last 2 bytes) → empty model.
                guard bs.count >= 12 else { return EquilCmdModel() }
                let codeByte = [bs[10], bs[11]]
                list.append(bs[bs.count - 2])
                list.append(bs[bs.count - 1])
                model.code = EquilUtils.bytesToHex(codeByte).lowercased()
            } else {
                guard bs.count >= 6 else { continue }
                for i in 6 ..< bs.count { list.append(bs[i]) }
            }
        }
        model.ciphertext = EquilUtils.bytesToHex(list).lowercased()
        model.tag = ""
        model.iv = ""
        return model
    }

    // MARK: - Phase 1 completion: firmware version + next message

    func decode() throws -> EquilResponse? {
        var reqModel = decodeModel()
        let data = EquilUtils.hexStringToBytes(reqModel.ciphertext ?? "")
        // GUARD: incomplete ciphertext (assembled from leftover frames) → don't index
        // past data[12]/data[13] → throw, caught by decodeStep (response reset, wait).
        guard data.count >= 14 else {
            throw EquilError.invalidState("CmdDevicesOldGet: short response (\(data.count)B)")
        }
        // fv = data[12] + "." + data[13]  (both decimal Int)
        let fv = "\(Int(data[12])).\(Int(data[13]))"
        firmwareVersion = Float(fv) ?? 0
        reqModel.ciphertext = EquilUtils.bytesToHex(getNextData() ?? [])
        cmdSuccess = true
        return responseCmd(reqModel, port: "0000" + (reqModel.code ?? ""))
    }

    // MARK: - Phase 2 completion: confirmation

    override func decodeConfirmData(_ data: [UInt8]) {
        // fv = data[18] + "." + data[19]
        let fv = "\(Int(data[18])).\(Int(data[19]))"
        firmwareVersion = Float(fv) ?? 0
        cmdSuccess = true
    }

    // MARK: - Incoming state machine (BaseSetting-like, but custom decode())

    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }

    override func decodeConfirmStep() -> EquilResponse? {
        // CmdDevicesOldGet: phase 2 is confirmation only (decodeConfirmData),
        // no further outgoing message — BaseSetting decodeConfirm() would
        // call decodeConfirmData(), then send getNextData(); here
        // confirmation ends the process (cmdSuccess already true).
        let model = decodeModel()
        let data = EquilUtils.hexStringToBytes(model.ciphertext ?? "")
        if data.count >= 20 { decodeConfirmData(data) } else { cmdSuccess = true }
        return nil
    }

    // MARK: - Support check (firmware 5.3 threshold)

    /// RELAXED firmware gate: ANY serial-number prefix is pairable if firmware
    /// is ABOVE 1.0 (EQUIL_SUPPORT_LEVEL = 1.0). No SN-prefix based rejection.
    /// Only invalid / missing / sub-1.0 firmware is rejected.
    /// (Resistance threshold SN-prefix logic is NOT a gate — it's priming calibration,
    /// lives separately in EquilConst.resistanceThreshold; unaffected here.)
    func isSupport(serialNumber _: String) -> Bool {
        firmwareVersion >= EquilConst.EQUIL_SUPPORT_LEVEL
    }
}
