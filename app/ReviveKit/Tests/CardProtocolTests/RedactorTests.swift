import CardProtocol
import CardTestSupport
import Foundation
import Testing

// Evidence redaction (CLAUDE.md rule 4): nothing that identifies the card or decrypts its audio.
struct RedactorTests {
    let serial = "SN1234567890ABCD"

    @Test func deviceInfoHidesSerialAndAddress() throws {
        let body = #"{"sn":"\#(serial)","v":"1.50","btaddr":"A1B2C3D4E5F6","bat":47}"#
        let s = Redactor.describe(FakeCard.frame(0x80, Data(body.utf8)), .rx)
        #expect(!s.contains(serial))
        #expect(!s.contains("A1B2C3D4"))
        #expect(s.contains("sha256:" + Redactor.serialTag(serial)))
        #expect(s.contains("…E5F6"))
        #expect(s.contains("\"v\":\"1.50\""))
    }

    @Test func serialTagIsEightHexDigits() {
        let tag = Redactor.serialTag(serial)
        #expect(tag.count == 8 && tag.allSatisfy(\.isHexDigit))
    }

    @Test func unparsableDeviceInfoShowsOnlySize() {
        let s = Redactor.describe(FakeCard.frame(0x80, Data("sn=\(serial)".utf8)), .rx)
        #expect(!s.contains(serial))
    }

    @Test func bondIdNeverShown() throws {
        let bondId = Data((1...16).map { UInt8($0) })
        let idHex = bondId.map { String(format: "%02X", $0) }.joined(separator: " ")
        let tx = Redactor.describe(try CardRequest.bond(bondId: bondId).encode(), .tx)
        let rx = Redactor.describe(FakeCard.frame(0xA1, Data([1]) + bondId), .rx)
        for s in [tx, rx] {
            #expect(!s.contains(idHex) && !s.contains("01 02 03 04"))
            #expect(s.contains("<bondId 16 B>"))
        }
        #expect(Redactor.describe(FakeCard.frame(0xA1, Data([0])), .rx) == "A1 len=1 00")
    }

    @Test func encryptionKeyNeverShown() throws {
        let key = AudioCrypto.deviceKey(serial: serial)
        let s = Redactor.describe(try CardRequest.setEncryptionKey(enabled: true, key: key).encode(), .tx)
        #expect(s == "A2 len=33 01 <key 32 B>")
    }

    @Test func chunkShowsHeaderNotAudio() {
        let audio = Data("encrytSECRETAUDIO".utf8)
        let s = Redactor.describe(FakeCard.frame(0x70, Data([0x20, 0, 0, 1, 0]) + audio), .rx)
        #expect(s == "70 len=22 status=0x20 offset=256 data=<17 B>")
    }

    @Test func textAndBinaryPayloads() {
        #expect(Redactor.describe(FakeCard.frame(0x51, Data("NULL".utf8)), .rx) == "51 len=4 NULL")
        #expect(Redactor.describe(FakeCard.frame(0xA3, Data([0x01])), .rx) == "A3 len=1 01")
        #expect(Redactor.describe(Data([0x00, 0x01]), .rx) == "<not a frame, 2 B>")
    }
}
