import XCTest
@testable import DNoteProbe

final class AudioCodecTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// RFC 8439 §2.4.2 test vector.
    func testChaCha20RFC8439() {
        let key = [UInt8](0...31)
        let nonce: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0]
        let text = [UInt8]("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let out = chacha20(key: key, nonce: nonce, data: text, counter: 1)
        XCTAssertEqual(Data(out.prefix(16)).hex, "6e2e359a2568f98041ba0728dd0d6981")
        XCTAssertEqual(Data(out.suffix(2)).hex, "874d")
    }

    /// Fixtures come from tools/make_fixtures.py (Python reference implementation).
    func testDecryptMatchesPython() throws {
        let plain = try decryptAudioFile(try fixture("encrypted.bin"))
        XCTAssertEqual(plain, try fixture("plain.bin"))
    }

    func testDecryptRejectsTamperedHeader() throws {
        var enc = try fixture("encrypted.bin")
        enc[10] ^= 0xFF
        XCTAssertThrowsError(try decryptAudioFile(enc))
    }

    func testOggMatchesPython() throws {
        let frames = splitOpusFrames(try fixture("plain.bin"))
        XCTAssertEqual(frames.count, 123)
        XCTAssertEqual(wrapOpusFramesAsOgg(frames), try fixture("expected_ogg.bin"))
    }

    func testFrameCodec() throws {
        XCTAssertEqual(buildFrame(Cmd.queryFileList).hex, "a09000")
        XCTAssertEqual(frameBond(Data(repeating: 0x11, count: 16)).hex, "a0a01101" + String(repeating: "11", count: 16))
        let f = try XCTUnwrap(parseFrame(Data([0xA0, 0x70, 0x07, 0x20, 0, 0, 0, 5, 0xAB, 0xCD])))
        let chunk = FileChunk(f.body)
        XCTAssertEqual(chunk.status, FileStatus.eof)
        XCTAssertEqual(chunk.offset, 5)
        XCTAssertEqual(chunk.data.hex, "abcd")
        XCTAssertNil(parseFrame(Data([0xA0, 0x90, 0x05, 0x00])))
    }

    func testAdvertisementParse() throws {
        // CID 0x22A3 little-endian, then BID, PID, fw 1.50, hw 1.0, battery 87, power 1, SID.
        let md = Data([0xA3, 0x22, 0, 1, 0, 2, 1, 50, 1, 0, 87, 1, 0x01, 0x02, 0x03])
        let info = try XCTUnwrap(AdvInfo(manufacturerData: md))
        XCTAssertEqual(info.firmware, "v1.50")
        XCTAssertEqual(info.battery, 87)
        XCTAssertEqual(info.sid, 0x010203)
        XCTAssertNil(AdvInfo(manufacturerData: Data([0x4C, 0x00] + [UInt8](repeating: 0, count: 13))))
    }
}
