# V3 pairing (H1) — 2026-11-06

Device: `853BE462-3927-35DC-A23E-F592DFD35491`, fw v1.50, encryption on.
Precondition: all 9 recordings backed up via `pull` (not committed; see `.gitignore`).

## Commands
```
python dnote.py --address $A pair            # 00: refuses, card bonded to a foreign bondId
for i in 1 2 3: unpair; pair                 # r{i}-*.log
python dnote.py --address $A pair            # 04: idempotent, skipped
list; pull --name 20261106035009.opus        # 05: decrypt still works after re-pair
```

## Criteria
- H1 holds "no reconnect needed" iff, in every round, the same-connection `0xA1` query already reflects the `0xA0` write.

## Result
- 3/3 unpair and 3/3 pair: effective on the same connection and after reconnect → **no reconnect needed**.
- `0xA0` (bond and unbond) replies with a 1-byte `0x01` ack (undocumented before).
- After unbind, `0xA1` returns `isBonded=0` with no bondId.
- Re-running `pair` with the stored bondId is a no-op.
- Post re-pair download is byte-identical to the backup (sha256 `0c0813…a9bf`).

# V3 button recording (H5) and BLE throughput — 2026-11-06

## Commands
```
status; list                                          # 06: list empty while recording; file appears after stop
pull --name 20261106040350.opus --out /tmp/v3tp/runN   # 07: x3, sequential
ffprobe / ffmpeg -f null / volumedetect on run1 output
```

## Criteria
- H5 holds iff the button-recorded file is listed by `0x90`, downloads, decrypts, and decodes without error with non-silent audio.
- Throughput = file size / download wall time reported by `pull`, ≥ 1 MB, ≥ 3 runs.

## Result
- H5 holds: 15,180,060 B, Opus 48 kHz mono, 7590 s, full decode OK, mean volume −24.2 dB (first 600 s).
- While recording, `0x90` returns an empty list (`0x56` shows rec=1); after stop, all 10 files are listed.
- Throughput: 640.7 / 645.8 / 643.3 s → 23.69 / 23.51 / 23.60 KB/s, mean 23.60 KB/s (±0.4%).
- All 3 downloads are byte-identical after decode (`07-throughput.sha256`).
- Audio itself is not committed.
