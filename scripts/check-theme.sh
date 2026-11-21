#!/usr/bin/env bash
# Static check for docs/design-spec.md §2: views take colours from Theme, not literals (#74).
#   Every *.swift under app/Revive/ except Common/Theme.swift (where the tokens are defined)
#   and Debug/ (DEBUG-only screens) must not contain a colour literal or a system colour that
#   the design spec replaces. System warning/error colours (.red, .orange) stay allowed.
# Exit status is non-zero on any violation; the offending lines are printed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
views="$root/app/Revive"

patterns=(
  # Colour values: Color(red:...), Color(white:), Color(hue:...), Color(hex:...) helpers.
  'Color\([[:space:]]*(red|white|hue|hex)'
  'UIColor\([[:space:]]*(red|white|hue|hex|displayP3Red)[[:space:]]*:'
  '#colorLiteral'
  # System backgrounds and fills that Theme.paper / Theme.surface replace.
  'Color\([[:space:]]*uiColor:[[:space:]]*\.system'
  'Color\([[:space:]]*\.system'
  'UIColor\.system'
  '\.background\([[:space:]]*\.bar\b'
  '\.(quaternary|quinary)\b'
  # Shadows (use Theme.shadow) and tinted washes (use Theme tokens).
  'Color\.black\.opacity'
  'Color\.(orange|yellow|green|blue|gray|purple|pink)\.opacity'
)
regex="$(IFS='|'; echo "${patterns[*]}")"

# The Mac views (ADR-011) use system styling and have no Theme yet: no colour literals either.
hits=$(grep -rnE "$regex" "$views" "$root/app/ReviveMac" --include='*.swift' \
  --exclude-dir=Debug | grep -v "^$views/Common/Theme.swift:" || true)

if [[ -n "$hits" ]]; then
  echo "FAIL: colour literal outside Theme (docs/design-spec.md §2.1); use a Theme token:"
  echo "$hits"
  exit 1
fi
echo "OK: theme colour check passes"
