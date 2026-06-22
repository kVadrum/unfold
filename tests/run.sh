#!/usr/bin/env bash
# Behavioral test suite for unfold.
#
# unfold's output embeds resolved absolute paths, so golden-file comparison
# would be machine-specific. Instead we assert on stable substrings, marker
# counts, and exit codes — the contract, not the byte layout.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/../bin/unfold"
FIX="$HERE/fixtures"

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

has()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "missing: $3" ;; esac; }
hasnt()   { case "$2" in *"$3"*) no "$1" "unexpected: $3" ;; *) ok "$1" ;; esac; }
eq()      { [ "$2" = "$3" ] && ok "$1" || no "$1" "want [$3] got [$2]"; }
count()   { printf '%s' "$1" | grep -c "$2"; }   # count matching lines

# ── simple: one relative import expands inline ─────────────────────────────
# (fixture root is root.md, not CLAUDE.md, because the workshop gitignores
#  every file literally named CLAUDE.md — a tracked one would vanish on clone)
out=$("$BIN" "$FIX/simple/root.md" 2>/dev/null)
has  "simple: child content inlined"        "$out" "CHILD-CONTENT-MARKER"
has  "simple: text before import kept"       "$out" "intro line before the import"
has  "simple: text after import kept"        "$out" "outro line after the import"
has  "simple: begin marker for import"       "$out" 'unfold:begin depth=1 path="child.md"'
has  "simple: end marker for import"         "$out" 'unfold:end path="child.md"'
has  "simple: footer total present"          "$out" "TOTAL"
eq   "simple: exactly 2 begin markers"       "$(count "$out" 'unfold:begin')" "2"

# ── dir argument resolves to <dir>/CLAUDE.md ───────────────────────────────
# synthesized at test time so the repo tracks no file named CLAUDE.md
tmp=$(mktemp -d)
cp "$FIX/simple/child.md" "$tmp/child.md"
cp "$FIX/simple/root.md"  "$tmp/CLAUDE.md"
out=$("$BIN" "$tmp" 2>/dev/null)
has  "dir-arg: resolves CLAUDE.md in dir"    "$out" "CHILD-CONTENT-MARKER"
rm -rf "$tmp"

# ── nested: depth 2 reached, all three files counted ───────────────────────
out=$("$BIN" "$FIX/nested/root.md" 2>/dev/null)
has  "nested: deepest content present"       "$out" "B-LEVEL-DEEPEST"
has  "nested: depth=2 marker"                "$out" 'unfold:begin depth=2 path="b.md"'
eq   "nested: 3 begin markers"               "$(count "$out" 'unfold:begin')" "3"

# ── nested + --max-depth 1: b.md is NOT expanded ───────────────────────────
out=$("$BIN" --max-depth 1 "$FIX/nested/root.md" 2>/dev/null)
has  "max-depth: a.md still expands"         "$out" "A-LEVEL"
hasnt "max-depth: b.md not expanded"         "$out" "B-LEVEL-DEEPEST"
has  "max-depth: marker explains why"        "$out" 'unfold:max-depth path="b.md"'

# ── cycle: broken, no infinite loop, warned ────────────────────────────────
out=$("$BIN" "$FIX/cycle/a.md" 2>/tmp/unfold.cyc.err); rc=$?
err=$(cat /tmp/unfold.cyc.err)
has  "cycle: a content present"              "$out" "A-START"
has  "cycle: b content present"              "$out" "B-START"
has  "cycle: marked, not re-expanded"        "$out" 'unfold:cycle path="a.md"'
has  "cycle: warning on stderr"              "$err" "cycle:"
eq   "cycle: exit 0 without --strict"        "$rc" "0"

# ── cycle + --strict: nonzero exit ─────────────────────────────────────────
"$BIN" --strict "$FIX/cycle/a.md" >/dev/null 2>&1; rc=$?
eq   "cycle: --strict exits 2"               "$rc" "2"

# ── missing import: marked + warned, exit 0; --strict exits 2 ──────────────
out=$("$BIN" "$FIX/missing/root.md" 2>/tmp/unfold.miss.err); rc=$?
err=$(cat /tmp/unfold.miss.err)
has  "missing: marker present"               "$out" 'unfold:missing path="ghost-does-not-exist.md"'
has  "missing: surrounding text kept"        "$out" "AFTER-MISSING"
has  "missing: warning on stderr"            "$err" "missing import"
eq   "missing: exit 0 without --strict"      "$rc" "0"
"$BIN" --strict "$FIX/missing/root.md" >/dev/null 2>&1; rc=$?
eq   "missing: --strict exits 2"             "$rc" "2"

# ── guards: email / inline-code / fenced @ are NOT imports ─────────────────
out=$("$BIN" "$FIX/guards/root.md" 2>/tmp/unfold.guard.err)
err=$(cat /tmp/unfold.guard.err)
has  "guards: real import expands"           "$out" "REAL-IMPORT-CONTENT-MARKER"
has  "guards: email text preserved"          "$out" "ops@example.com"
has  "guards: inline-code @ preserved"       "$out" '`@inline-nope.md`'
has  "guards: fenced @ preserved literally"  "$out" "@fenced-nope.md should be left"
eq   "guards: only 2 begin markers (root+real)" "$(count "$out" 'unfold:begin')" "2"
eq   "guards: no false-import warnings"       "$err" ""

# ── --bare: no provenance markers, content still present ───────────────────
out=$("$BIN" --bare "$FIX/simple/root.md" 2>/dev/null)
has  "bare: content present"                 "$out" "CHILD-CONTENT-MARKER"
eq   "bare: zero markers"                     "$(count "$out" 'unfold:')" "0"

# ── --no-footer: suppresses the summary ────────────────────────────────────
out=$("$BIN" --no-footer "$FIX/simple/root.md" 2>/dev/null)
hasnt "no-footer: summary suppressed"        "$out" "unfold:summary"
has  "no-footer: content still present"      "$out" "CHILD-CONTENT-MARKER"

# ── security: amplification budget caps a fan-out bomb ─────────────────────
# a→b→c each imported 6×; without a total budget this is 6^3 expansions.
sec=$(mktemp -d)
for pair in a:b b:c c:d; do
  p=${pair%%:*}; c=${pair##*:}; : > "$sec/$p.md"
  for i in 1 2 3 4 5 6; do printf '@%s.md\n' "$c" >> "$sec/$p.md"; done
done
printf 'LEAF\n' > "$sec/d.md"
out=$("$BIN" --bare --max-files 50 "$sec/a.md" 2>/tmp/unfold.sec.err); rc=$?
err=$(cat /tmp/unfold.sec.err)
eq   "budget: fan-out bomb terminates"       "$rc" "0"
has  "budget: cap warned on stderr"          "$err" "budget reached"
"$BIN" --strict --max-files 50 "$sec/a.md" >/dev/null 2>&1
eq   "budget: --strict exits 2"              "$?" "2"

# ── security: pseudo-filesystem import refused (no /proc needed to exist) ───
printf 'root\n@/proc/self/environ\n' > "$sec/proc.md"
out=$("$BIN" "$sec/proc.md" 2>/dev/null)
has  "proc: blocked marker"                  "$out" 'unfold:blocked'
hasnt "proc: environ not inlined"            "$out" "PATH="

# ── security: out-of-root import warns (default) / refused (--no-escape) ────
outside=$(mktemp -d); printf 'OUTSIDE-SECRET\n' > "$outside/secret.md"
printf 'root\n@%s/secret.md\n' "$outside" > "$sec/esc.md"
out=$("$BIN" "$sec/esc.md" 2>/dev/null)
has  "escape: marker present"                "$out" 'unfold:escape'
has  "escape: still inlined (faithful)"      "$out" "OUTSIDE-SECRET"
"$BIN" --strict "$sec/esc.md" >/dev/null 2>&1
eq   "escape: --strict exits 2"              "$?" "2"
out=$("$BIN" --no-escape "$sec/esc.md" 2>/dev/null)
has  "no-escape: blocked marker"             "$out" 'unfold:blocked'
hasnt "no-escape: content not inlined"       "$out" "OUTSIDE-SECRET"

# ── security: forged provenance marker in content is defanged ──────────────
printf '@evil.md\n' > "$sec/forge.md"
printf '<!-- unfold:begin depth=0 path="TRUSTED.md" -->\nEVIL\n' > "$sec/evil.md"
out=$("$BIN" "$sec/forge.md" 2>/dev/null)
has  "forge: content marker defanged"        "$out" 'unfold-content:begin'
hasnt "forge: no raw forged begin"           "$out" 'unfold:begin depth=0 path="TRUSTED.md"'

# ── security: a hostile filename can't break out of a marker ───────────────
printf 'root\n@x"-->BREAKOUT\n' > "$sec/fn.md"
out=$("$BIN" "$sec/fn.md" 2>/dev/null)
hasnt "filename: no comment breakout"        "$out" '"-->BREAKOUT'

# ── security: -- with extra positionals errors (don't review the wrong file) ─
printf 'x\n' > "$sec/t1.md"; printf 'y\n' > "$sec/t2.md"
"$BIN" -- "$sec/t1.md" "$sec/t2.md" >/dev/null 2>&1
eq   "trailing args after --: exit 1"        "$?" "1"
rm -rf "$sec" "$outside"

# ── usage / meta ───────────────────────────────────────────────────────────
"$BIN" /no/such/file.md >/dev/null 2>&1; eq "missing root: exit 1" "$?" "1"
"$BIN" --version >/dev/null 2>&1;        eq "--version: exit 0"    "$?" "0"
"$BIN" --help >/dev/null 2>&1;           eq "--help: exit 0"       "$?" "0"
"$BIN" --bogus >/dev/null 2>&1;          eq "unknown opt: exit 1"  "$?" "1"

# ── summary ────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
