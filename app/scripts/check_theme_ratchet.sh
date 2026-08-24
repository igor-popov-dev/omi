#!/usr/bin/env bash
# Theme ratchet: inline colors (Color(0x…) / Colors.*) must not creep back into
# directories already migrated to OmiTokens (context.omi). Limits are the actual
# counts at migration time (waves T5–T7); every remaining match there is a
# deliberate exception (Classic halves of isGlass branches, Colors.transparent,
# brand hexes, categorical palettes). Lower a limit when you migrate more; never
# raise one without a design-doc reason.
#
# Usage: scripts/check_theme_ratchet.sh   (run from app/)
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
check() {
  local dir="$1" limit="$2"
  local n
  n=$(grep -rE 'Color\(0x|Colors\.' "$dir" --include='*.dart' 2>/dev/null | grep -v 'wrapped_2025' | wc -l | tr -d ' ')
  if [ "$n" -gt "$limit" ]; then
    echo "RATCHET FAIL: $dir has $n inline colors (limit $limit). Use context.omi tokens (lib/utils/theme/)."
    fail=1
  else
    echo "ok: $dir $n/$limit"
  fi
}

check lib/pages/home 24
check lib/pages/conversations 35
check lib/pages/chat 31
check lib/pages/action_items 21
check lib/pages/memories 18
check lib/pages/conversation_detail 21
check lib/widgets 28
check lib/pages/settings 155
check lib/pages/apps 117

exit $fail
