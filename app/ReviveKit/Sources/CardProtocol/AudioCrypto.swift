import CryptoKit
import Foundation

// Port of decrypt_audio_file (client/dnote_protocol.py, PROTOCOL.md §6.2).
// Output must be byte-identical to the Python reference.

public enum AudioError: Error, Equatable, Sendable {
    case tooShort
    case notEncrypted
    /// Header check failed: wrong key or corrupt file (app error `decryptFailed`).
    case decryptFailed
}

public enum AudioCrypto {
    /// Key extracted from the official app. Together with a card's `sn` it yields that
    /// card's audio key, so evidence must never record a full `sn` (CLAUDE.md rule 4, ADR-006).
    static let deviceKeySecret = Data([
        58, 127, 209, 158, 82, 196, 139, 6, 175, 45, 232, 116, 25, 92, 179, 240,
        110, 161, 71, 220, 131, 47, 149, 107, 12, 212, 231, 56, 242, 26, 142, 89,
    ])

    /// Audio key the card is given at pairing (`0xA2`): HMAC-SHA256(secret, sn).
    public static func deviceKey(serial: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(serial.utf8), using: SymmetricKey(data: deviceKeySecret)))
    }

    public static func isEncrypted(_ buf: Data) -> Bool {
        buf.count >= 6 && buf.prefix(6).elementsEqual("encryt".utf8)
    }

    /// Layout: [0:24] header (magic + 18 bytes key material), [24:36] nonce, [36:] ciphertext.
    /// The first 24 plaintext bytes must equal the header. Returns the raw Opus stream.
    public static func decrypt(_ buf: Data) throws -> Data {
        let b = [UInt8](buf)
        guard b.count >= 60 else { throw AudioError.tooShort }
        guard isEncrypted(buf) else { throw AudioError.notEncrypted }
        let key = HMAC<SHA256>.authenticationCode(for: Data(b[6..<24]), using: SymmetricKey(data: deviceKeySecret))
        let plain = try chacha20(key: Data(key), nonce: Data(b[24..<36]), data: Data(b[36...]))
        guard plain.prefix(24).elementsEqual(b[0..<24]) else { throw AudioError.decryptFailed }
        return Data(plain.dropFirst(24))
    }

    /// Raw ChaCha20 (RFC 8439) with a 12-byte nonce and initial counter 0.
    ///
    /// CryptoKit only exposes the AEAD, whose cipher stream starts at counter 1. Block 0 is
    /// computed here and the rest is taken from ChaChaPoly's ciphertext (tag discarded), which
    /// keeps multi-MB files fast even in unoptimized builds.
    static func chacha20(key: Data, nonce: Data, data: Data) throws -> Data {
        let block0 = keystreamBlock(key: [UInt8](key), nonce: [UInt8](nonce), counter: 0)
        var out = Data(zip(data.prefix(64), block0).map { $0 ^ $1 })
        if data.count > 64 {
            let sealed = try ChaChaPoly.seal(data.dropFirst(64), using: SymmetricKey(data: key),
                                             nonce: ChaChaPoly.Nonce(data: nonce))
            out.append(sealed.ciphertext)
        }
        return out
    }

    /// One 64-byte ChaCha20 keystream block (RFC 8439 §2.3).
    static func keystreamBlock(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        func word(_ p: [UInt8], _ i: Int) -> UInt32 {
            UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
        }
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x6170_7865; state[1] = 0x3320_646e; state[2] = 0x7962_2d32; state[3] = 0x6b20_6574
        for i in 0..<8 { state[4 + i] = word(key, i * 4) }
        state[12] = counter
        for i in 0..<3 { state[13 + i] = word(nonce, i * 4) }

        var x = state
        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 16 | x[d] >> 16
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 12 | x[b] >> 20
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 8 | x[d] >> 24
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 7 | x[b] >> 25
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        return (0..<16).flatMap { i -> [UInt8] in
            let k = x[i] &+ state[i]
            return (0..<4).map { UInt8(truncatingIfNeeded: k >> (8 * UInt32($0))) }
        }
    }
}
