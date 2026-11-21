"""Linux-only edits to the mirrored sources for scripts/linux-test.sh; never applied to the repo.

Each edit replaces one Apple-only API with what Linux Foundation offers, or removes code that
cannot exist there. A missing anchor fails loudly, so a source change that moves the code is
noticed instead of silently testing something else.
"""
import pathlib
import sys

w = pathlib.Path(sys.argv[1])


def edit(rel, old, new):
    p = w / rel
    s = p.read_text()
    if old not in s:
        sys.exit(f"linux-test: anchor not found in {rel}; update scripts/linux/patch.py")
    p.write_text(s.replace(old, new, 1))


def cut(rel, start, end, keep_end=True):
    p = w / rel
    s = p.read_text()
    try:
        a = s.index(start)
        b = s.index(end, a)
    except ValueError:
        sys.exit(f"linux-test: anchor not found in {rel}; update scripts/linux/patch.py")
    p.write_text(s[:a] + (s[b:] if keep_end else s[b + len(end):]))


# CryptoKit -> swift-crypto: same API for SHA256, AES and HMAC.
for p in list((w / "Sources").rglob("*.swift")) + list((w / "Tests").rglob("*.swift")):
    s = p.read_text()
    if "import CryptoKit" in s:
        p.write_text(s.replace("import CryptoKit", "import Crypto"))

# The "important usage" capacity key is Apple-only.
edit("Sources/Library/AudioStore.swift",
     """        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0""",
     """        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)""")

# Keychain is Apple-only: keep the protocol and the in-memory store the tests use.
edit("Sources/CardService/BondStore.swift", "import Security\n", "")
cut("Sources/CardService/BondStore.swift", "public final class KeychainBondStore", "public final class InMemoryBondStore")

# The system Opus encoder (AVFoundation) is Apple-only.
cut("Tests/CardProtocolTests/OpusTOCTests.swift", "    /// Packets from the system encoder",
    "    }\n", keep_end=False)
