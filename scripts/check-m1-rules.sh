#!/usr/bin/env bash
# Static checks for CLAUDE.md hard rules 1 and 3 (test-spec.md §3.5 gate 1).
#   1. No irreversible device command literals (0x93 factory reset, 0x94 format,
#      0xB0/0xB1 firmware upgrade) in app, client or prototype sources. Test code is
#      exempt so it can assert the whitelist.
#   2. M1 modules in ReviveKit must not use networking APIs.
#   3. SyncEngine knows devices only through DeviceSource (ADR-010): it must not import
#      the D·NOTE modules, so a second device needs no change to the sync state machine.
# Exit status is non-zero on any violation.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app"
fail=0

# The Python client and the iOS prototype talk to real cards too: same rule, same exemption for tests.
forbidden=$(grep -rniE '0x(93|94|b0|b1)\b' "$app" "$root/client" "$root/ios-prototype" \
  --include='*.swift' --include='*.py' --exclude-dir=Tests --exclude-dir=tests --exclude-dir=.build \
  --exclude-dir=.build-linux --exclude-dir=.venv || true)
if [[ -n "$forbidden" ]]; then
  echo "FAIL: irreversible device command literal found (CLAUDE.md rule 1):"
  echo "$forbidden"
  fail=1
fi

# LibraryTools and the revive tool (features.md X19) are offline too, though not part of M1.
m1_modules=(CardProtocol CardLink CardService DeviceSource Library SyncEngine Player Transcription AppModel LibraryTools revive)
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

# The Assistant module talks to AI services over the network, LinkImport downloads podcast
# links (features.md X12), and Account talks to our backend (features.md K1). Device and offline
# modules must not import any of them (CLAUDE.md rule 3): only the app shell and AppModel's AI,
# link-import and account screens may.
offline_modules=(CardProtocol CardLink CardService DeviceSource Library SyncEngine Player Transcription LibraryTools revive)
for m in "${offline_modules[@]}"; do
  dir="$app/ReviveKit/Sources/$m"
  [[ -d "$dir" ]] || continue
  uses=$(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(Assistant|LinkImport|Account)\b' "$dir" --include='*.swift' || true)
  if [[ -n "$uses" ]]; then
    echo "FAIL: offline module $m imports a networking module (CLAUDE.md rule 3):"
    echo "$uses"
    fail=1
  fi
done

# SyncEngine and DeviceSource are device-neutral (ADR-010): no D·NOTE module behind them.
for m in SyncEngine DeviceSource; do
  dir="$app/ReviveKit/Sources/$m"
  [[ -d "$dir" ]] || continue
  uses=$(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(CardProtocol|CardLink|CardService)\b' \
    "$dir" --include='*.swift' || true)
  if [[ -n "$uses" ]]; then
    echo "FAIL: device-neutral module $m imports a D·NOTE module (ADR-010):"
    echo "$uses"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "OK: M1 static rules pass"
fi
exit $fail
