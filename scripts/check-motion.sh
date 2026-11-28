#!/usr/bin/env bash
# Static check for docs/design-spec.md §2.3: one motion language. Views animate only through
# app/Revive/Common/Motion.swift (Motion tokens, withMotion, .motion(_:value:), .motionTransition,
# .pressable), which also honours Reduce Motion. A raw SwiftUI animation anywhere else under
# app/Revive or app/ReviveMac (which shares Motion.swift) invents its own curve and ignores
# Reduce Motion.
#   Fix: pick the token for the kind of change (Motion.tap / .standard / .overlay / .follow) and
#   write  withMotion(Motion.standard) { … }  or  .motion(Motion.standard, value: x)  or
#   .motionTransition(.fade / .top / .pop)  instead.
# Debug/ (DEBUG-only screens) is exempt. Exit status is non-zero on any violation.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
views="$root/app/Revive"

patterns=(
  # Explicit and implicit animations: go through withMotion / .motion.
  '\bwithAnimation[[:space:]]*[({]'
  '\.animation\('
  # Insertion and removal: go through .motionTransition.
  '\.transition\('
  # Number rolls, icon morphs and nods: go through .motionNumber / .motionSymbolReplace /
  # .motionNod, which fall back to a fade (or stillness) under Reduce Motion.
  'contentTransition\([[:space:]]*\.(numericText|symbolEffect)'
  'symbolEffect\([[:space:]]*\.bounce'
  # The wrappers take a Motion token, never a curve written inline.
  '(\.motion|withMotion)\([[:space:]]*[^M[:space:]]'
  # Curves written inline instead of a Motion token.
  'Animation\.(default|linear|easeIn|easeOut|easeInOut|spring|interactiveSpring|interpolatingSpring|bouncy|smooth|snappy)\b'
  '\.(easeIn|easeOut|easeInOut|interactiveSpring|interpolatingSpring)\('
)
regex="$(IFS='|'; echo "${patterns[*]}")"

hits=$(grep -rnE "$regex" "$views" "$root/app/ReviveMac" --include='*.swift' --exclude-dir=Debug \
  | grep -v "^$views/Common/Motion.swift:" || true)

if [[ -n "$hits" ]]; then
  echo "FAIL: animation outside Motion.swift (docs/design-spec.md §2.3)."
  echo "Use a Motion token: withMotion(Motion.standard) { … }, .motion(Motion.tap, value: x),"
  echo ".motionTransition(.fade | .top | .pop), .motionNumber(x), .motionSymbolReplace(),"
  echo ".motionNod(value: x), or .buttonStyle(.pressable):"
  echo "$hits"
  exit 1
fi
echo "OK: motion check passes"
