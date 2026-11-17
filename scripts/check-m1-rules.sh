#!/usr/bin/env bash
# Static checks for CLAUDE.md hard rules 1 and 3 (test-spec.md §3.5 gate 1).
#   1. No irreversible device command literals (0x93 factory reset, 0x94 format,
#      0xB0/0xB1 firmware upgrade) anywhere in app sources. Test code is exempt
#      so it can assert the whitelist.
#   2. M1 modules in ReviveKit must not use networking APIs.
# Exit status is non-zero on any violation.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app"
fail=0

forbidden=$(grep -rniE '0x(93|94|b0|b1)\b' "$app" \
  --include='*.swift' --exclude-dir=Tests --exclude-dir=.build || true)
if [[ -n "$forbidden" ]]; then
  echo "FAIL: irreversible device command literal found (CLAUDE.md rule 1):"
  echo "$forbidden"
  fail=1
fi

m1_modules=(CardProtocol CardLink CardService Library SyncEngine Player Transcription AppModel)
for m in "${m1_modules[@]}"; do
  dir="$app/ReviveKit/Sources/$m"
  [[ -d "$dir" ]] || continue
  net=$(grep -rnE '\bimport (Network|FoundationNetworking)\b|URLSession|URLRequest|NWConnection|NSURLConnection|CFNetwork' \
    "$dir" --include='*.swift' || true)
  if [[ -n "$net" ]]; then
    echo "FAIL: networking API in M1 module $m (CLAUDE.md rule 3):"
    echo "$net"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "OK: M1 static rules pass"
fi
exit $fail
