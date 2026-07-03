import Foundation

final class CmdDevicesOldGet: EquilBaseSetting {
    let address: String
    private(set) var firmwareVersion: Float = 0

    init(address: String, createTime: Int64) {
        self.address = address
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        port = "0E0E"
    }

    // MARK: - 1. üzenet: fix 14-byte, TITKOSÍTÁS NÉLKÜL

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

    // MARK: - SAJÁT decodeModel (NINCS tag/iv; ciphertext = nyers byte-ok)

    override func decodeModel() -> EquilCmdModel {
        var model = EquilCmdModel()
        var list: [UInt8] = []
        guard let response = response, !response.send.isEmpty else { return model }
        for (index, bs) in response.send.enumerated() {
            if index == 0 {
                // VÉDELEM (pumpacsere/párosítás race): csonka (stray/maradék) első keret
                // esetén NEM indexelünk túl ([10],[11] + utolsó 2 byte) → üres modell.
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

    // MARK: - 1. fázis lezárása: firmware-verzió + következő üzenet

    func decode() throws -> EquilResponse? {
        var reqModel = decodeModel()
        let data = EquilUtils.hexStringToBytes(reqModel.ciphertext ?? "")
        // VÉDELEM: hiányos (maradék-keretből összeállt) ciphertext esetén NE indexeljünk
        // túl a data[12]/data[13]-on → dobunk, amit a decodeStep elkap (response-reset, vár).
        guard data.count >= 14 else {
            throw EquilError.invalidState("CmdDevicesOldGet: rövid válasz (\(data.count)B)")
        }
        // fv = data[12] + "." + data[13]  (mindkettő decimális Int)
        let fv = "\(Int(data[12])).\(Int(data[13]))"
        firmwareVersion = Float(fv) ?? 0
        reqModel.ciphertext = EquilUtils.bytesToHex(getNextData() ?? [])
        cmdSuccess = true
        return responseCmd(reqModel, port: "0000" + (reqModel.code ?? ""))
    }

    // MARK: - 2. fázis lezárása: megerősítés

    override func decodeConfirmData(_ data: [UInt8]) {
        // fv = data[18] + "." + data[19]
        let fv = "\(Int(data[18])).\(Int(data[19]))"
        firmwareVersion = Float(fv) ?? 0
        cmdSuccess = true
    }

    // MARK: - Beérkező állapotgép (BaseSetting-azonos, de saját decode())

    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime)
            return nil }
    }

    override func decodeConfirmStep() -> EquilResponse? {
        // CmdDevicesOldGet: a 2. fázis csak megerősítés (decodeConfirmData),
        // nincs további kimenő üzenet — a BaseSetting decodeConfirm() a
        // decodeConfirmData()-t hívja, majd getNextData()-t küldene; itt a
        // megerősítés a folyamat vége (cmdSuccess már true).
        let model = decodeModel()
        let data = EquilUtils.hexStringToBytes(model.ciphertext ?? "")
        if data.count >= 20 { decodeConfirmData(data) } else { cmdSuccess = true }
        return nil
    }

    // MARK: - Támogatottság-ellenőrzés (firmware 5.3 küszöb)

    /// LAZÍTOTT firmware-gate: MINDEN sorozatszám-prefix párosítható, ha a firmware
    /// 1.0 FELETT van (EQUIL_SUPPORT_LEVEL = 1.0). Nincs SN-prefix alapú elutasítás.
    /// Csak az érvénytelen / hiányzó / 1.0 alatti firmware-t utasítjuk el.
    /// (A resistance threshold SN-prefix logikája NEM gate — az priming-kalibráció,
    /// külön él az EquilConst.resistanceThreshold-ban; ezt nem érinti.)
    func isSupport(serialNumber _: String) -> Bool {
        firmwareVersion >= EquilConst.EQUIL_SUPPORT_LEVEL
    }
}
