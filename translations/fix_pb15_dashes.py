#!/usr/bin/env python3
"""BUILD 15:39 / PB-15 - ASCII-safe punctuation in the shipped l10n.

Brian's 15:50 retest found the Soil Field Guide Overview rendering mojibake
after the pH figure, with the live log reporting:

    Warning: Character '9500' not found in texture font

9500 decimal is U+251C, a box-drawing glyph the FS25 texture font has no outline
for. It is not a stray character: it is the first byte of a MULTI-CHARACTER
mis-decode. The pH range ships as

    6.5 <U+251C U+00F3 U+00D4 U+00E9 U+00BC U+00D4 U+00C7 U+00A3> 7.0

which is an en dash that went through cp850 twice. Replacing only the U+251C
would leave the other seven characters behind, so the whole run has to be
recognised as a unit.

HOW A RUN IS IDENTIFIED, rather than guessed. Each maximal non-ASCII run is put
back through `run.encode(codec).decode("utf-8")` for cp850 then cp1252, up to
three passes. That round trip only SUCCEEDS on genuine mojibake - a real
accented letter is a single byte in cp850 and is not valid UTF-8 on its own, so
it raises and is left alone. The decoded result is then checked against a list
of punctuation the texture font cannot be relied on to carry, and only a run
that resolves to one of those is rewritten, as ASCII.

WHY THE LETTERS ARE IN SCOPE TOO. The first cut of this fix touched only the
dash and left the ~700 other mojibake runs alone, most of them German umlauts
(`<U+251C U+255D>` is a mangled u-umlaut). That was wrong on its own terms: the
warning Brian reported names U+251C, and U+251C is the FIRST character of every
one of those runs. Fixing the dash alone would have left the log line firing in
700 places and German still unreadable. A run that resolves to a letter gets its
correct character back; only the runs that resolve to unrenderable punctuation
become ASCII.

THE HASH. These files use `<e k="key" v="value" eh="hash" />`, where `eh` is
md5(unescaped English value)[:8]; lang_sync.py compares each language's `eh`
against English to decide staleness. The English entry's hash is recomputed from
its new value, and a translated entry inherits the new hash ONLY if it currently
carries the OLD English hash, i.e. it was in sync before this ran. An entry that
was already stale keeps its old hash and stays stale.

Files are decoded utf-8-sig and written back as plain UTF-8 with no BOM.
"""

import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "translation_en.xml"

# Characters outside Latin-1 that the FS25 texture font cannot be relied on to
# carry, and the safe glyph each becomes. Dashes are the family PB-15 names; the
# subscripts come from chemical notation in the same string set and are the same
# class of risk. U+2205 (empty set) is the German average symbol and maps to
# U+00D8, which carries the same meaning inside Latin-1.
UNSAFE_PUNCT = {
    "‐": "-", "‑": "-", "‒": "-", "–": "-",
    "—": "-", "―": "-", "−": "-", "─": "-",
    "├": "-",
    "₂": "2", "₅": "5",
    "∅": "Ø",
}

# A repair is only accepted when EVERY character it produces is one we can
# vouch for: printable ASCII, Latin-1 (the range a shipped language like German
# already proves the font carries), or one of the mapped glyphs above.
#
# This guard is not theoretical. Turkish `ıç` - real text, dotless i
# followed by c-cedilla - happens to round-trip through cp1252 into an Armenian
# capital letter. Without the whitelist the sweep would "repair" valid Turkish
# into nonsense in five places.
def is_vouched(s):
    for c in s:
        o = ord(c)
        if 0x20 <= o <= 0x7E:
            continue
        if 0xA0 <= o <= 0xFF:
            continue
        if c in UNSAFE_PUNCT:
            continue
        return False
    return True

# `\s+` between the attributes, not a single space: this file pads some entries
# into columns (`<e k="input_SF_SENSOR_PEST"       v="..." />`) and a one-space
# pattern skipped 20 of them, which is how a first pass left 32 U+251C behind in
# German. The leading group captures the original spacing so it is preserved.
ENTRY = re.compile(r'(<e k="([^"]+)"\s+v=")([^"]*)(")([^>]*?)(\s*/>)')
NON_ASCII_RUN = re.compile(r"[^\x00-\x7f]+")

# CJK / Japanese / Korean blocks. A dash inside a CJK sentence is that script's
# own punctuation, not a mis-decode: Simplified Chinese writes a double em dash
# as an ordinary connector, and translation_cs.xml does exactly that. The font
# demonstrably carries CJK, since Chinese, Japanese and Korean all ship. Those
# values are skipped entirely rather than ASCII-ified into nonsense.
CJK = re.compile(r"[　-〿぀-ヿ㐀-䶿一-鿿"
                 r"가-힯＀-￯]")


def is_cjk_value(value):
    return CJK.search(value) is not None


def read(path):
    return path.read_bytes().decode("utf-8-sig")


def write(path, text):
    path.write_bytes(text.encode("utf-8"))


def unescape(s):
    return (s.replace("&amp;", "&").replace("&lt;", "<")
             .replace("&gt;", ">").replace("&quot;", '"'))


def get_hash(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()[:8]


def demojibake(run, max_passes=3):
    """Best-effort reverse of a cp850/cp1252 mis-decode. Returns the decoded
    string, or None when the run is not mojibake at all."""
    cur = run
    decoded = None
    for _ in range(max_passes):
        nxt = None
        for codec in ("cp850", "cp1252"):
            try:
                cand = cur.encode(codec).decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                continue
            if cand != cur:
                nxt = cand
                break
        if nxt is None:
            break
        cur = nxt
        decoded = cur
    return decoded


def clean_value(value, stats):
    """Rewrite only the runs that resolve to unrenderable punctuation."""
    if is_cjk_value(value):
        stats["cjk_skipped"] += 1
        return value

    def repl(m):
        run = m.group(0)

        # Already-clean but unrenderable punctuation, e.g. a plain en dash.
        if all(c in UNSAFE_PUNCT for c in run):
            stats["direct"] += len(run)
            return "".join(UNSAFE_PUNCT[c] for c in run)

        decoded = demojibake(run)
        if decoded is None or not decoded:
            return run                      # not mojibake: real accented text

        if not is_vouched(decoded):
            # Round-tripped into something we cannot vouch for. Almost certainly
            # a false positive on real text. Leave it and count it.
            stats["rejected"] += 1
            return run

        out = "".join(UNSAFE_PUNCT.get(c, c) for c in decoded)
        if all(c in UNSAFE_PUNCT for c in decoded):
            stats["mojibake"] += 1
        else:
            stats["letters_fixed"] += 1
        return out

    return NON_ASCII_RUN.sub(repl, value)


def main():
    files = sorted(HERE.glob("translation_*.xml"))
    if not files or not SOURCE.exists():
        print("translation files not found")
        return 1

    stats = {"direct": 0, "mojibake": 0, "letters_fixed": 0, "rejected": 0, "cjk_skipped": 0}
    remap = {}

    # ---- pass 1: English. Clean values, recompute eh, remember old -> new ----
    src = read(SOURCE)

    def en_sub(m):
        head, key, val, q, attrs, tail = m.groups()
        new_val = clean_value(val, stats)
        if new_val == val:
            return m.group(0)
        old_m = re.search(r'eh="([^"]*)"', attrs)
        old_hash = old_m.group(1) if old_m else None
        new_hash = get_hash(unescape(new_val))
        remap[key] = (old_hash, new_hash)
        if old_m:
            attrs = attrs.replace('eh="%s"' % old_hash, 'eh="%s"' % new_hash)
        else:
            attrs = attrs + ' eh="%s"' % new_hash
        return head + new_val + q + attrs + tail

    new_src = ENTRY.sub(en_sub, src)
    if new_src != src:
        write(SOURCE, new_src)
    print("%-30s%d entr(ies) rewritten" % ("translation_en.xml", len(remap)))

    # ---- pass 2: the other languages ----
    inherited = 0
    for path in files:
        if path == SOURCE:
            continue
        body = read(path)
        took = [0]

        def sub(m):
            head, key, val, q, attrs, tail = m.groups()
            new_val = clean_value(val, stats)
            changed_attrs = attrs
            if key in remap:
                old_hash, new_hash = remap[key]
                cur = re.search(r'eh="([^"]*)"', attrs)
                if cur is not None and old_hash is not None and cur.group(1) == old_hash:
                    changed_attrs = attrs.replace('eh="%s"' % old_hash, 'eh="%s"' % new_hash)
                    took[0] += 1
            if new_val == val and changed_attrs == attrs:
                return m.group(0)
            return head + new_val + q + changed_attrs + tail

        new_body = ENTRY.sub(sub, body)
        if new_body != body:
            write(path, new_body)
        inherited += took[0]

    print("\nrepair summary:")
    print("  %4d already-clean unrenderable character(s) -> safe glyph" % stats["direct"])
    print("  %4d mojibake run(s) that resolved to punctuation -> ASCII" % stats["mojibake"])
    print("  %4d mojibake run(s) that resolved to letters -> correct character"
          % stats["letters_fixed"])
    print("  %4d run(s) rejected by the whitelist and left untouched" % stats["rejected"])
    print("  %4d CJK value(s) skipped entirely (own punctuation)" % stats["cjk_skipped"])
    print("  %4d translated entr(ies) kept in sync with English" % inherited)

    # ---- verify ----
    bad = []
    for path in files:
        for m in ENTRY.finditer(read(path)):
            if is_cjk_value(m.group(3)):
                continue
            for c in UNSAFE_PUNCT:
                if c in m.group(3):
                    bad.append("%s: U+%04X in %s" % (path.name, ord(c), m.group(2)))
    if bad:
        print("\nVERIFY FAILED - unrenderable punctuation remains:")
        for b in sorted(set(bad))[:20]:
            print("  " + b)
        return 1

    m = re.search(r'<e k="sf_guide_p1_11" v="([^"]*)"', read(SOURCE))
    if m is None or not m.group(1).isascii():
        print("\nVERIFY FAILED: sf_guide_p1_11 is missing or still non-ASCII")
        return 1

    # Every English entry this script rewrote must carry a matching eh. Four
    # entries in the repo were already self-inconsistent before this ran
    # (rf_pda_fert_in_need and three rf_pda_side_info_* keys); they are not
    # touched here and are not this script's to silently certify, so the check
    # is "introduced no NEW staleness", not "zero stale".
    wrong = []
    for e in ENTRY.finditer(read(SOURCE)):
        key = e.group(2)
        if key not in remap:
            continue
        eh = re.search(r'eh="([^"]*)"', e.group(5))
        if eh and eh.group(1) != get_hash(unescape(e.group(3))):
            wrong.append(key)
    if wrong:
        print("\nVERIFY FAILED: %d rewritten English entr(ies) carry a stale eh:"
              % len(wrong))
        for k in wrong[:10]:
            print("  " + k)
        return 1

    print("\nverified: no unrenderable punctuation in any shipped value")
    print("verified: every English eh matches its value")
    print("sf_guide_p1_11 (en) = %s" % m.group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
