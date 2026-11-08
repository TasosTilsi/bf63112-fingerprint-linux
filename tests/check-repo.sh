#!/usr/bin/env bash
# Repository gate. Refuses to pass if this tree contains anything that must
# never be published, or if the scripts do not parse, or if the pinned values
# drift away from what the docs claim.
#
# Usage:  tests/check-repo.sh            run the gate
#         tests/check-repo.sh --self-test run the gate plus a negative control
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$REPO" || exit 1
fail=0
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
ok()  { printf '  ok    %s\n' "$*"; }

echo "== 1. no proprietary or biometric material =="
hits="$(find . -path ./.git -prune -o -type f \
        \( -iname '*.dll' -o -iname '*.cab' -o -iname '*.exe' -o -iname '*.msi' \
           -o -iname '*.pgm' -o -iname '*.variant' -o -iname '*.orig' \) -print 2>/dev/null)"
if [ -n "$hits" ]; then
    while IFS= read -r f; do bad "must not ship: $f"; done <<< "$hits"
else
    ok "no binaries, vendor packages, images or templates"
fi

echo "== 2. shell scripts parse =="
for s in install.sh tests/check-repo.sh; do
    if bash -n "$s" 2>/dev/null; then ok "$s"; else bad "$s does not parse"; fi
done

echo "== 3. probe script compiles =="
if python3 -m py_compile probe-id.py 2>/dev/null; then
    ok "probe-id.py"
else
    bad "probe-id.py does not compile"
fi
rm -rf __pycache__

echo "== 4. pinned values are consistent with the docs =="
sha="$(grep -oE 'MATCHER_SHA256="[0-9a-f]{64}"' install.sh | head -1 | cut -d'"' -f2)"
pin="$(grep -oE 'UPSTREAM_PIN="[0-9a-f]{40}"' install.sh | head -1 | cut -d'"' -f2)"
sid="$(grep -oE 'SENSOR_ID="0x[0-9a-f]+"' install.sh | head -1 | cut -d'"' -f2)"
[ -n "$sha" ] && ok "matcher sha256 pinned" || bad "matcher sha256 not pinned"
[ -n "$pin" ] && ok "upstream commit pinned" || bad "upstream commit not pinned"
[ "$sid" = "0x5f83" ] && ok "sensor id 0x5f83" || bad "sensor id unexpected: '$sid'"
grep -qF "$sha" README.md || bad "README does not mention the pinned matcher hash"
grep -qF "$pin" README.md || bad "README does not mention the pinned commit"
grep -qF "$sha" NOTICE   || bad "NOTICE does not mention the pinned matcher hash"
[ -f COPYING ] && ok "COPYING present" || bad "COPYING missing"
[ -f NOTICE ]  && ok "NOTICE present"  || bad "NOTICE missing"

echo "== 5. attribution to the upstream project =="
for f in README.md NOTICE; do
    grep -qi 'dedbin/libfprint-bf63112' "$f" \
        && ok "$f credits dedbin/libfprint-bf63112" \
        || bad "$f does not credit dedbin/libfprint-bf63112"
done

echo "== 6. no secrets or local absolute paths leaked =="
# The checker itself must contain these patterns, so it is excluded from its own
# scan; so is NOTICE, which legitimately names the OEM component.
leaks="$(grep -rnE 'tasostilsi|gho_[A-Za-z0-9]|BEGIN [A-Z ]*PRIVATE KEY|hotmail\.com' \
         --include='*.sh' --include='*.py' --include='*.md' . 2>/dev/null \
         | grep -v '^./NOTICE:' | grep -v '^./tests/check-repo.sh:' || true)"
if [ -n "$leaks" ]; then
    while IFS= read -r l; do bad "possible leak: $l"; done <<< "$leaks"
else
    ok "no personal identifiers or secrets"
fi

if [ "${1:-}" = "--self-test" ]; then
    echo "== 7. negative control: the gate must go RED on a planted DLL =="
    tmp="$(mktemp -d)"
    cp -r . "$tmp/repo" 2>/dev/null
    printf 'MZ fake\n' > "$tmp/repo/BetterlifeEngineAdapter.dll"
    if "$tmp/repo/tests/check-repo.sh" >/dev/null 2>&1; then
        bad "gate stayed GREEN with a planted DLL: it cannot see what it claims to check"
    else
        ok "gate correctly went RED"
    fi
    chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"
fi

echo
if ((fail)); then
    echo "GATE: RED"
    exit 1
fi
echo "GATE: GREEN"
