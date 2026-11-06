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
