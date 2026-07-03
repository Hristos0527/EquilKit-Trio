import Foundation

/// Equivalent to EquilResponse: the list of outgoing BLE packets.
public struct EquilResponse {
    let createTime: Int64
    var send: [[UInt8]] = []

    init(createTime: Int64) { self.createTime = createTime }

    mutating func add(_ packet: [UInt8]) { send.append(packet) }
}

public class EquilBaseCmd {
    // MARK: - Companion (static, shared) state — BaseCmd.companion

    static let DEFAULT_PORT = "0F0F"
    static var reqIndex: Int = 0
    static var pumpReqIndex: Int = 10
    static var rspIndex: Int = -1

    /// Call BEFORE a command sequence (pairing or bolus).
    /// Resets shared indices to AAPS initial values.
    static func resetState() {
        reqIndex = 0
        pumpReqIndex = 10
        rspIndex = -1
    }

    // MARK: - Instance state

    let createTime: Int64
    var port: String = "0404"
    var config: Bool = false
    var isEnd: Bool = false
    public var cmdSuccess: Bool = false
    public var enacted: Bool = true
    var response: EquilResponse?
    var runPwd: String?
    var runCode: String?

    /// Pairing/SN/password data injected (from Preferences in AAPS).
    var equilDevice: String // stored device hex (SN-derived)
    var equilPassword: String // stored 64-hex password

    init(createTime: Int64, equilDevice: String, equilPassword: String) {
        self.createTime = createTime
        self.equilDevice = equilDevice
        self.equilPassword = equilPassword
    }

    func getEquilDevices() -> String { equilDevice }
    func getEquilPassWord() -> String { equilPassword }

    // MARK: - Bit operations (BaseCmd)

    func toNewStart(_ number: UInt8) -> UInt8 { number & ~(1 << 7) }
    func toNewEndConf(_ number: UInt8) -> UInt8 { number | (1 << 7) }
    func isEnd(_ b: UInt8) -> Bool { getBit(b, 7) == 1 }
    func getIndex(_ b: UInt8) -> Int { Int(b) & 63 }
    func getBit(_ b: UInt8, _ i: Int) -> Int { (Int(b) >> i) & 0x1 }

    /// BaseCmd.convertString — prepend "0" before every character.
    func convertString(_ input: String) -> String {
        var sb = ""
        for ch in input { sb += "0"
            sb.append(ch) }
        return sb
    }

    func up1(_ value: Double) -> Int { Int(ceil(value)) }

    // MARK: - checkData (BaseCmd.checkData)

    /// Validate incoming packet: index != previous index, and crc8Maxim matches.
    ///
    /// GUARD (priming race): on a held-open connection, leftover/repeated notify frames
    /// from the previous step can slip through. Indexing a truncated (<6 byte) frame
    /// was previously a fatal trap (Array out of range), so BEFORE every index access
    /// we check length. Too-short frames are invalid → discard (return false),
    /// so the decoder accumulator stays clean. BLE payload is NOT changed.
    func checkData(_ data: [UInt8]) -> Bool {
        guard data.count >= 6 else { return false }
        if let response = response, !response.send.isEmpty {
            let preData = response.send[response.send.count - 1]
            guard preData.count >= 4 else { return false }
            let index = Int(data[3]) & 0xFF
            let preIndex = Int(preData[3]) & 0xFF
            if index == preIndex { return false }
        }
        let crc = Int(data[5]) & 0xFF
        let crc1 = Crc.crc8Maxim(Array(data[0 ..< 5]))
        if crc != crc1 { return false }
        return true
    }

    // MARK: - responseCmd (BaseCmd.responseCmd) — critical BLE framing

    /// Packs EquilCmdModel (tag|iv|ciphertext) into BLE packets,
    /// then reqIndex++.
    func responseCmd(_ model: EquilCmdModel, port: String) -> EquilResponse {
        let packets = EquilFraming.responseCmd(
            port: port,
            tag: model.tag ?? "",
            iv: model.iv ?? "",
            ciphertext: model.ciphertext ?? "",
            reqIndex: EquilBaseCmd.reqIndex
        )
        var resp = EquilResponse(createTime: createTime)
        resp.send = packets
        EquilBaseCmd.reqIndex += 1
        return resp
    }

    // MARK: - decodeModel (BaseCmd.decodeModel)

    /// Reconstructs tag/iv/ciphertext fields from received packet fragments.
    /// Packet structure: first packet payload is last 4 bytes + code at [10,11],
    /// subsequent packets from byte 6 to end.
    func decodeModel() -> EquilCmdModel {
        var model = EquilCmdModel()
        var list: [UInt8] = []
        guard let response = response, !response.send.isEmpty else { return model }
        for (index, bs) in response.send.enumerated() {
            if index == 0 {
                // First packet contains code ([10],[11]) and last 4 payload bytes.
                // GUARD: truncated (stray/leftover) frame → no out-of-bounds indexing → empty model.
                // With empty model, decode()/decodeConfirm() AESUtil.decrypt
                // throws decryptMissingField, caught by decodeStep/decodeConfirmStep
                // handled with response reset (no crash, just waits for real frame).
                guard bs.count >= 12 else { return EquilCmdModel() }
                // last 4 bytes
                for i in (bs.count - 4) ..< bs.count { list.append(bs[i]) }
                let codeByte = [bs[10], bs[11]]
                model.code = EquilUtils.bytesToHex(codeByte).lowercased()
            } else {
                // Continuation packet payload from byte 6; shorter frames
                // (leftover/ack) are invalid fragments → skip (range 6..<count crash guard).
                guard bs.count >= 6 else { continue }
                for i in 6 ..< bs.count { list.append(bs[i]) }
            }
        }
        // list split: tag(0..16), iv(16..28), ciphertext(28..).
        // GUARD: tag(16)+iv(12) = 28 byte minimum; less means incomplete packet
        // (leftover frame) → empty model so range slices don't index out of bounds.
        guard list.count >= 28 else { return EquilCmdModel() }
        let list1 = Array(list[0 ..< 16])
        let list2 = Array(list[16 ..< (12 + 16)])
        let list3 = Array(list[(12 + 16) ..< list.count])
        model.iv = EquilUtils.bytesToHex(list2).lowercased()
        model.tag = EquilUtils.bytesToHex(list1).lowercased()
        model.ciphertext = EquilUtils.bytesToHex(list3).lowercased()
        return model
    }

    // MARK: - decodeEquilPacket (BaseSetting/CmdPair state machine)

    //
    //  Collects individual packets from BLE notify; when packet isEnd
    //  bit (bit7) is set, runs the decode step for that phase.
    //  Two phases based on `config` flag:
    //    - config == false → phase 1: collect, then decode() → 2nd message payload,
    //                        config = true.
    //    - config == true  → phase 2: collect, then decodeConfirm() → 3rd message /
    //                        siker (isEnd = true).
    //
    //  decode()/decodeConfirm() steps provided by subclass (BaseSetting/CmdPair).
    //  Return value: next outgoing EquilResponse, or nil if no
    //  complete message yet (or process finished).
    public func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
        guard checkData(data) else { return nil }
        let code = data[4]
        let intValue = getIndex(code)

        if config {
            if EquilBaseCmd.rspIndex == intValue { return nil } // duplicate packet
            let flag = isEnd(code)
            response?.add(data)
            if !flag { return nil }
            let next = decodeConfirmStep()
            isEnd = true
            response = EquilResponse(createTime: createTime)
            EquilBaseCmd.rspIndex = intValue
            return next
        }

        let flag = isEnd(code)
        response?.add(data)
        if !flag { return nil }
        let next = decodeStep()
        response = EquilResponse(createTime: createTime)
        config = true
        EquilBaseCmd.rspIndex = intValue
        return next
    }

    /// Phase 1 completion (BaseSetting/CmdPair `decode()`). Subclass overrides.
    func decodeStep() -> EquilResponse? { nil }
    /// Phase 2 completion (BaseSetting/CmdPair `decodeConfirm()`). Subclass overrides.
    func decodeConfirmStep() -> EquilResponse? { nil }

    // MARK: - EquilCommandDriving basics (runner calls these)

    //
    //  `decodeEquilPacket`, `cmdSuccess`, `enacted` live here on base class — shared by all
    //  commands. `label` and `firstResponse()` are command-specific: base provides default
    //  (subclass overrides). Thus `EquilBaseCmd: EquilCommandDriving` conformance
    //  is satisfied in one place on base; CmdPair/CmdLargeBasalSet only override.
    var commandLabel: String { "Equil command" }
    func makeFirstResponse() throws -> EquilResponse {
        throw EquilError.invalidState("firstResponse not implemented (\(type(of: self)))")
    }
}

public protocol EquilCommandDriving: AnyObject {
    var label: String { get }
    var cmdSuccess: Bool { get }
    var enacted: Bool { get }
    func firstResponse() throws -> EquilResponse
    func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse?
}

extension EquilBaseCmd: EquilCommandDriving {
    public var label: String { commandLabel }
    public func firstResponse() throws -> EquilResponse { try makeFirstResponse() }
}
