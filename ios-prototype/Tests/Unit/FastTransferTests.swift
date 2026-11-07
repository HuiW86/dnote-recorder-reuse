import XCTest
@testable import DNoteProbe

final class FastTransferTests: XCTestCase {
    /// ft-list.bin is the card's real reply to `list_files` (22 recordings, #6 probe 2026-11-07).
    func testParsesRealListReply() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ft-list.bin", withExtension: nil))
        var buf = try Data(contentsOf: url)
        var entries: [FTListEntry] = []
        while let f = try FTFrame.parse(&buf) {
            XCTAssertEqual(f.type, FTFrame.Kind.list.rawValue)
            XCTAssertEqual(f.status, 0)
            entries.append(try XCTUnwrap(FTListEntry(f.body)))
        }
        XCTAssertTrue(buf.isEmpty)
        XCTAssertEqual(entries.count, 23)
        XCTAssertEqual(entries.first, FTListEntry(index: 1, total: 22, size: 22060, name: "20261105203844.opus"))
        XCTAssertTrue(try XCTUnwrap(entries.last).isEnd)
        XCTAssertFalse(entries.dropLast().contains { $0.isEnd })
        let big = try XCTUnwrap(entries.first { $0.name == "20261106040350.opus" })
        XCTAssertEqual(big.size, 15_180_060)
    }

    func testStatusOnlyReply() throws {
        var buf = Data([0xaa, 0x05, 0x01, 0x00, 0x00])
        XCTAssertEqual(try FTFrame.parse(&buf), FTFrame(type: 0x05, status: 0x01, body: Data()))
        XCTAssertTrue(buf.isEmpty)
    }

    func testPartialFrameWaitsForMore() throws {
        var buf = frame(type: 0x01, body: chunkBody(total: 4, offset: 0, data: [1, 2, 3, 4]))
        let full = buf
        buf.removeLast()
        XCTAssertNil(try FTFrame.parse(&buf))
        XCTAssertEqual(buf.count, full.count - 1, "an incomplete frame must stay buffered")
    }

    func testBadMagicThrows() {
        var buf = Data([0x00, 0x01, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try FTFrame.parse(&buf))
    }

    /// Layout seen on the card: total | offset | chunk | 2 bytes | data.
    func testChunkReassembly() throws {
        var buf = frame(type: 0x01, body: chunkBody(total: 6, offset: 0, data: [1, 2, 3, 4]))
            + frame(type: 0x01, body: chunkBody(total: 6, offset: 4, data: [5, 6]))
        let a = try FTChunk(try XCTUnwrap(try FTFrame.parse(&buf)).body)
        let b = try FTChunk(try XCTUnwrap(try FTFrame.parse(&buf)).body)
        XCTAssertEqual(a.offset, 0)
        XCTAssertFalse(a.isLast)
        XCTAssertEqual(b.offset, 4)
        XCTAssertTrue(b.isLast)
        XCTAssertEqual(a.data + b.data, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(a.tag, Data("SB".utf8))
    }

    func testChunkLengthMismatchThrows() {
        var body = chunkBody(total: 4, offset: 0, data: [1, 2, 3, 4])
        body.removeLast()
        XCTAssertThrowsError(try FTChunk(body))
    }

    private func frame(type: UInt8, status: UInt8 = 0, body: Data) -> Data {
        Data([0xaa, type, status, UInt8(body.count >> 8), UInt8(body.count & 0xff)]) + body
    }

    private func chunkBody(total: Int, offset: Int, data: [UInt8]) -> Data {
        func u32(_ v: Int) -> Data { Data((0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) }) }
        return u32(total) + u32(offset) + u32(data.count) + Data("SB".utf8) + Data(data)
    }
}

extension FTListEntry {
    init(index: Int, total: Int, size: Int, name: String) {
        func u32(_ v: Int) -> Data { Data((0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) }) }
        self.init(u32(index) + u32(total) + u32(size) + Data(name.utf8) + Data([0]))!
    }
}
