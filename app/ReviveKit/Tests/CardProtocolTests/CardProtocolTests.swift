import Foundation
import Testing
import CardTestSupport
@testable import CardProtocol

// Protocol unit tests T-M1-01..03, 05..07 (test-spec.md §3.1). T-M1-04 is in OggOpusTests.

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Frames produced by client/dnote_protocol.py (scripts/make_fixtures.py).
func pythonFrames() throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: fixture("frame_vectors.json"))
}

struct WhitelistTests {
    /// prd.md §2.2, M1 rows only.
    static let m1Whitelist: Set<UInt8> = [
        0x80, 0x81, 0x56, 0xA1, 0xA3,                       // queries
        0x83, 0x84, 0x85, 0x8B, 0x8C, 0x8D, 0x8F, 0x87,     // settings
        0x51, 0x50, 0x52, 0x53,                             // recording
        0x90, 0x70, 0x91,                                   // files
        0xA0, 0xA2,                                         // pairing
    ]

    // T-M1-01: only whitelisted bytes map to a Command; outgoing frames need a Command.
    @Test func onlyWhitelistedCommandsExist() {
        let constructible = Set((0...255).map(UInt8.init).filter { Command(rawValue: $0) != nil })
        #expect(constructible == Self.m1Whitelist)
        #expect(Command.allCases.count == Self.m1Whitelist.count)
    }

    @Test(arguments: [0x93, 0x94, 0xB0, 0xB1, 0x89, 0x82, 0x86, 0x88, 0x8A, 0x95, 0x92, 0x68] as [UInt8])
    func forbiddenAndLaterMilestoneCommandsCannotBeBuilt(cmd: UInt8) {
        #expect(Command(rawValue: cmd) == nil)
    }

    @Test func everyRequestEncodesToItsWhitelistedCommand() throws {
        for request in allRequests {
            let frame = try request.encode()
            #expect(Self.m1Whitelist.contains(frame[1]), "\(request)")
            #expect(frame[1] == request.command.rawValue)
        }
    }
}

let allRequests: [CardRequest] = [
    .deviceInfo, .switches, .recordingStatus, .bondStatus, .encryptionStatus,
    .set(.led(true)), .set(.motor(false)), .set(.noiseCancel(true)), .set(.vad(false)),
    .set(.gain(1)), .set(.gain(9)), .set(.noiseLevel(5)), .set(.autoOff(seconds: 600)),
    .syncTime(Date(timeIntervalSince1970: 0), TimeZone(identifier: "UTC")!),
    .startRecording, .stopRecording, .pauseRecording, .resumeRecording,
    .listFiles, .download(name: "a.opus", offset: 0), .delete(name: "a.opus"),
    .bond(bondId: Data(repeating: 0x11, count: 16)), .unbond,
    .setEncryptionKey(enabled: true, key: Data(repeating: 1, count: 32)),
]

struct FrameCodecTests {
    // T-M1-02: byte-identical to the Python client.
    @Test func requestsMatchPythonClient() throws {
        let py = try pythonFrames()
        let cases: [(String, CardRequest)] = [
            ("deviceInfo", .deviceInfo), ("switches", .switches), ("recordingStatus", .recordingStatus),
            ("bondStatus", .bondStatus), ("encryptionStatus", .encryptionStatus),
            ("ledOn", .set(.led(true))), ("motorOff", .set(.motor(false))),
            ("noiseCancelOn", .set(.noiseCancel(true))), ("vadOff", .set(.vad(false))),
            ("gain1", .set(.gain(1))), ("gain9", .set(.gain(9))), ("noiseLevel5", .set(.noiseLevel(5))),
            ("autoOff600", .set(.autoOff(seconds: 600))),
            ("syncTime", .syncTime(Date(timeIntervalSince1970: 1_794_043_805), TimeZone(identifier: "UTC")!)),
            ("startRecording", .startRecording), ("stopRecording", .stopRecording),
            ("pauseRecording", .pauseRecording), ("resumeRecording", .resumeRecording),
            ("listFiles", .listFiles),
            ("download", .download(name: "20261106080407.opus", offset: 0)),
            ("downloadResume", .download(name: "20261106080407.opus", offset: 474_030)),
            ("delete", .delete(name: "20261106080407.opus")),
            ("bond", .bond(bondId: Data(repeating: 0x11, count: 16))), ("unbond", .unbond),
            ("setEncryptionKey", .setEncryptionKey(enabled: true, key: AudioCrypto.deviceKey(serial: "TESTSN0001"))),
        ]
        #expect(Set(cases.map(\.0)) == Set(py.keys), "every Python vector is covered")
        for (name, request) in cases {
            #expect(try request.encode().hex == py[name], "\(name)")
        }
    }

    @Test func syncTimeUsesGivenTimeZone() throws {
        // 2026-11-07 09:30:05 UTC is 17:30:05 in Shanghai.
        let date = Date(timeIntervalSince1970: 1_794_043_805)
        let frame = try CardRequest.syncTime(date, TimeZone(identifier: "Asia/Shanghai")!).encode()
        #expect(String(decoding: frame.dropFirst(3), as: UTF8.self) == #"{"time":"20261107173005"}"#)
    }

    @Test func payloadLengthBoundaries() throws {
        #expect(try Frame.encode(.listFiles).hex == "a09000")
        let max = try Frame.encode(.listFiles, Data(repeating: 0x61, count: 255))
        #expect(max.count == 258 && max[2] == 0xFF)
        #expect(throws: ProtocolError.payloadTooLong(256)) { try Frame.encode(.listFiles, Data(count: 256)) }
        let longName = String(repeating: "x", count: 250)
        #expect(throws: ProtocolError.self) { try CardRequest.delete(name: longName).encode() }
    }

    @Test func parseValidFrames() throws {
        let empty = try #require(Frame.parse(Data([0xA0, 0x55, 0x00])))
        #expect(empty.cmd == 0x55 && empty.body.isEmpty && empty.push == .recordingStopped)
        let full = Data([0xA0, 0x90, 0xFF]) + Data(repeating: 0x20, count: 255)
        #expect(try #require(Frame.parse(full)).body.count == 255)
        // Bytes beyond LEN are ignored, as in the Python client.
        let trailing = try #require(Frame.parse(Data([0xA0, 0x50, 0x01, 0x01, 0xEE])))
        #expect(trailing.isAck && trailing.command == .stopRecording)
    }

    @Test func parseRejectsInvalidFrames() {
        #expect(Frame.parse(Data()) == nil)
        #expect(Frame.parse(Data([0xA0, 0x90])) == nil)
        #expect(Frame.parse(Data([0xA1, 0x90, 0x00])) == nil, "wrong PID")
        #expect(Frame.parse(Data([0xA0, 0x90, 0x05, 0x00])) == nil, "LEN larger than data")
    }

    @Test func invalidArgumentsAreRejected() {
        #expect(throws: ProtocolError.self) { try CardRequest.bond(bondId: Data(count: 15)).encode() }
        #expect(throws: ProtocolError.self) { try CardRequest.setEncryptionKey(enabled: true, key: Data(count: 31)).encode() }
        #expect(throws: ProtocolError.self) { try CardRequest.download(name: "", offset: 0).encode() }
        #expect(throws: ProtocolError.self) { try CardRequest.download(name: "a", offset: -1).encode() }
        #expect(throws: ProtocolError.self) { try CardRequest.delete(name: "").encode() }
    }
}

struct ResponseParsingTests {
    @Test func fileChunk() throws {
        let f = try #require(Frame.parse(Data([0xA0, 0x70, 0x07, 0x20, 0, 0, 0, 5, 0xAB, 0xCD])))
        #expect(FileChunk.parse(f) == FileChunk(status: .eof, offset: 5, data: Data([0xAB, 0xCD])))
        let statuses: [(UInt8, FileChunk.Status)] = [(0x00, .data), (0x10, .data), (0x2F, .eof), (0x30, .cancelled),
                                                    (0x40, .error), (0xF0, .notFound)]
        for (byte, status) in statuses {
            let frame = Frame(cmd: 0x70, body: Data([byte, 0, 0, 0, 0]))
            #expect(FileChunk.parse(frame)?.status == status)
        }
        #expect(FileChunk.parse(Frame(cmd: 0x70, body: Data([0x00, 0x00]))) == nil, "truncated header")
    }

    @Test func bondStatus() {
        let id = Data(repeating: 0x92, count: 16)
        #expect(BondStatus.parse(Frame(cmd: 0xA1, body: Data([1]) + id)) == BondStatus(isBonded: true, bondId: id))
        #expect(BondStatus.parse(Frame(cmd: 0xA1, body: Data([0]))) == BondStatus(isBonded: false, bondId: nil))
    }

    @Test func startRecordingReply() {
        let started = Frame(cmd: 0x51, body: Data(#"{"name":"20261106215528.opus"}"#.utf8))
        #expect(StartRecordingReply.parse(started) == .started(name: "20261106215528.opus"))
        #expect(StartRecordingReply.parse(Frame(cmd: 0x51, body: Data("NULL".utf8))) == .notPaired)
    }

    @Test func fileList() {
        let item = Frame(cmd: 0x90, body: Data(#"{"index":0,"name":"a.opus","size":18060,"end":0}"#.utf8))
        #expect(FileListMessage.parse(item) == .file(CardFile(name: "a.opus", size: 18060)))
        #expect(FileListMessage.parse(Frame(cmd: 0x90, body: Data(#"{"index":3,"end":1}"#.utf8))) == .end)
    }
}

struct AudioCryptoTests {
    /// RFC 8439 §2.4.2: block 1 of the sunscreen vector.
    @Test func keystreamMatchesRFC8439() {
        let key = [UInt8](0...31)
        let nonce: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0]
        let text = [UInt8]("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let ks = AudioCrypto.keystreamBlock(key: key, nonce: nonce, counter: 1)
        #expect(Data(zip(text, ks).map { $0 ^ $1 }.prefix(16)).hex == "6e2e359a2568f98041ba0728dd0d6981")
    }

    /// The CryptoKit-backed stream must equal the plain block-by-block cipher from counter 0.
    @Test func cryptoKitStreamMatchesBlockCipher() throws {
        var rng = SystemRandomNumberGenerator()
        let key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let nonce = (0..<12).map { _ in UInt8.random(in: 0...255, using: &rng) }
        for length in [0, 1, 63, 64, 65, 200, 1000] {
            let data = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var expected = [UInt8]()
            for (i, block) in stride(from: 0, to: length, by: 64).enumerated() {
                let ks = AudioCrypto.keystreamBlock(key: key, nonce: nonce, counter: UInt32(i))
                expected += zip(data[block..<min(block + 64, length)], ks).map { $0 ^ $1 }
            }
            #expect(try AudioCrypto.chacha20(key: Data(key), nonce: Data(nonce), data: Data(data)) == Data(expected))
        }
    }

    // T-M1-03
    @Test func decryptMatchesPython() throws {
        #expect(try AudioCrypto.decrypt(fixture("encrypted.bin")) == fixture("plain.bin"))
    }

    // Key material, nonce and the encrypted header copy; audio bytes carry no check.
    @Test(arguments: [6, 23, 30, 40, 59])
    func tamperedFileFailsVerification(byte: Int) throws {
        var enc = try fixture("encrypted.bin")
        enc[byte] ^= 0xFF
        #expect(throws: AudioError.decryptFailed) { try AudioCrypto.decrypt(enc) }
    }

    @Test func rejectsShortAndPlainFiles() throws {
        #expect(throws: AudioError.tooShort) { try AudioCrypto.decrypt(Data("encryt".utf8)) }
        #expect(throws: AudioError.notEncrypted) { try AudioCrypto.decrypt(fixture("plain.bin")) }
        #expect(AudioCrypto.isEncrypted(try fixture("encrypted.bin")))
    }

    @Test func deviceKeyMatchesPython() throws {
        // Vector setEncryptionKey = [A0 A2 21 01] + derive_device_key("TESTSN0001").
        let py = try #require(try pythonFrames()["setEncryptionKey"])
        #expect(AudioCrypto.deviceKey(serial: "TESTSN0001").hex == String(py.dropFirst(8)))
    }
}

struct AdvertisementTests {
    // T-M1-05, same input as the prototype test (prototype reported "v1.50").
    @Test func parsesCardAdvertisement() throws {
        // CID 0x22A3 little-endian, BID, PID, fw 1.50, hw 1.0, battery 87, power 1, SID.
        let md = Data([0xA3, 0x22, 0, 1, 0, 2, 1, 50, 1, 0, 87, 1, 0x01, 0x02, 0x03])
        let adv = try #require(Advertisement(manufacturerData: md))
        #expect(adv.firmware == "1.50")
        #expect(adv.hardware == "1.0")
        #expect(adv.battery == 87)
        #expect(adv.powerState == 1)
        #expect(adv.sid == 0x010203)
    }

    @Test func ignoresOtherVendorsAndShortData() {
        #expect(Advertisement(manufacturerData: Data([0x4C, 0x00] + [UInt8](repeating: 0, count: 13))) == nil)
        #expect(Advertisement(manufacturerData: Data([0xA3, 0x22, 0, 1])) == nil)
    }
}

struct FirmwareTests {
    // T-M1-06
    @Test func verifiedVersionHasNoWarning() {
        #expect(Firmware.check("1.50") == .verified)
        #expect(Firmware.check("v1.50") == .verified)
    }

    @Test(arguments: ["1.51", "1.5", "2.00", ""])
    func otherVersionsWarnButAreUsable(version: String) {
        #expect(Firmware.check(version) == .unverified(version: version))
    }
}

struct SettingTests {
    // T-M1-07: frames per PROTOCOL.md §4.1.
    @Test func settingFrames() throws {
        let cases: [(CardSetting, String)] = [
            (.led(true), "a0830101"), (.led(false), "a0830100"),
            (.motor(true), "a0840101"), (.noiseCancel(false), "a0850100"),
            (.vad(true), "a08b0101"), (.gain(4), "a08c0104"), (.noiseLevel(9), "a08d0109"),
            (.autoOff(seconds: 600), "a08f0400000258"), (.autoOff(seconds: 0x01020304), "a08f0401020304"),
        ]
        for (setting, hex) in cases {
            #expect(try CardRequest.set(setting).encode().hex == hex, "\(setting)")
        }
    }

    @Test(arguments: [0, 10, -1, 255])
    func levelsOutsideOneToNineAreRejected(level: Int) {
        #expect(throws: ProtocolError.self) { try CardRequest.set(.gain(level)).encode() }
        #expect(throws: ProtocolError.self) { try CardRequest.set(.noiseLevel(level)).encode() }
    }

    @Test func switchesReflectSettings() throws {
        let body = Data(#"{"ms":0,"led":1,"motor":1,"nc":1,"wav":0,"vad":0,"gain":4,"nn":4,"autoff":600}"#.utf8)
        let s = try #require(DeviceSwitches.parse(Frame(cmd: 0x81, body: body)))
        #expect(s.reflects(.led(true)) && s.reflects(.gain(4)) && s.reflects(.autoOff(seconds: 600)))
        #expect(!s.reflects(.vad(true)) && !s.reflects(.noiseLevel(5)))
    }
}
