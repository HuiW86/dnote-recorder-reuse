import CoreBluetooth
import Foundation

// Port of client/dnote_protocol.py (frame codec, advertisement parsing).
// Frame: [PID=0xA0][CMD][LEN][PAYLOAD...]

enum DNote {
    static let service = CBUUID(string: "00006001-0000-1000-8000-00805f9b34fb")
    static let writeChar = CBUUID(string: "00006002-0000-1000-8000-00805f9b34fb")
    static let notifyChar = CBUUID(string: "00006003-0000-1000-8000-00805f9b34fb")
    // SIG member service UUID carried in the advertisement; needed for background scans.
    static let advService = CBUUID(string: "FE98")
    static let pid: UInt8 = 0xA0
    static let companyId: UInt16 = 0x22A3
}

enum Cmd {
    static let queryDeviceInfo: UInt8 = 0x80
    static let queryFileList: UInt8 = 0x90
    static let stopRecording: UInt8 = 0x50
    static let queryRecStatus: UInt8 = 0x56
    static let requestFileData: UInt8 = 0x70
    static let bond: UInt8 = 0xA0
    static let queryBond: UInt8 = 0xA1
    static let queryChaCha20: UInt8 = 0xA3
    static let setWifiAp: UInt8 = 0x88
}

enum FileStatus {
    static let eof: UInt8 = 0x20
    static let cancelled: UInt8 = 0x30
    static let error: UInt8 = 0x40
    static let notFound: UInt8 = 0xF0
}

struct Frame {
    let cmd: UInt8
    let body: Data

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
    var text: String { String(decoding: body, as: UTF8.self) }
}

func buildFrame(_ cmd: UInt8, _ payload: Data = Data()) -> Data {
    precondition(payload.count <= 255, "payload too long for single-byte length field")
    return Data([DNote.pid, cmd, UInt8(payload.count)]) + payload
}

func buildFrame(_ cmd: UInt8, json: [String: Any]) -> Data {
    // Compact JSON with stable key order is not required by the device; keys are few.
    let body = try! JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
    return buildFrame(cmd, body)
}

func parseFrame(_ data: Data) -> Frame? {
    let b = [UInt8](data)
    guard b.count >= 3, b[0] == DNote.pid, b.count >= 3 + Int(b[2]) else { return nil }
    return Frame(cmd: b[1], body: Data(b[3..<3 + Int(b[2])]))
}

/// 0x70 chunk: [start(1)][offset(4,BE)][data...]
struct FileChunk {
    let status: UInt8
    let offset: UInt32
    let data: Data

    init(_ body: Data) {
        let b = [UInt8](body)
        guard b.count >= 5 else { status = 0; offset = 0; data = Data(); return }
        status = b[0] & 0xF0
        offset = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        data = Data(b[5...])
    }
}

struct AdvInfo {
    let firmware: String
    let hardware: String
    let battery: Int
    let powerState: Int
    let sid: Int

    /// CoreBluetooth manufacturer data: company ID little-endian, then the body.
    init?(manufacturerData md: Data) {
        let b = [UInt8](md)
        guard b.count >= 15, UInt16(b[0]) | UInt16(b[1]) << 8 == DNote.companyId else { return nil }
        // Offsets below follow PROTOCOL.md §2.2 minus the 2-byte CID.
        firmware = "v\(b[6]).\(b[7])"
        hardware = "v\(b[8]).\(b[9])"
        battery = Int(b[10])
        powerState = Int(b[11])
        sid = Int(b[12]) << 16 | Int(b[13]) << 8 | Int(b[14])
    }
}

func frameBond(_ bondId: Data) -> Data {
    precondition(bondId.count == 16, "bondId must be 16 bytes")
    return buildFrame(Cmd.bond, Data([1]) + bondId)
}

func frameRequestFile(_ name: String) -> Data {
    buildFrame(Cmd.requestFileData, json: ["cmd": 1, "name": name, "offset": 0])
}
