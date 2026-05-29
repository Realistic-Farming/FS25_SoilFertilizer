#!/usr/bin/env python3
"""
tools/gen_guide_translations.py

Adds l10n keys to all H/B entries in SoilGuideDialog.lua PAGE1-PAGE5
and the SUBTITLES array, updates _buildContent() and _selectPage() to
use tr(), and patches all 26 translation_XX.xml files with English entries
(other languages start with English text for translators to fill in).

Run from repo root: py tools/gen_guide_translations.py
"""

import re
import binascii
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
LUA_FILE = BASE / "src" / "ui" / "SoilGuideDialog.lua"
TRANS_DIR = BASE / "translations"

LANGS = ["en","de","fr","nl","it","pl","es","ea","pt","br","ru",
         "uk","cz","hu","ro","tr","fi","no","sv","da","kr","jp",
         "ct","fc","id","vi"]

# ── Helpers ──────────────────────────────────────────────────

def crc32_hex(s: str) -> str:
    return format(binascii.crc32(s.encode("utf-8")) & 0xFFFFFFFF, "08x")

def xml_attr(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;"))

def decode_lua_str(s: str) -> str:
    """Decode Lua string content with numeric byte escapes (\\NNN) to Python str."""
    result = bytearray()
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt.isdigit():
                j = i + 1
                while j < len(s) and s[j].isdigit() and (j - i - 1) < 3:
                    j += 1
                result.append(int(s[i+1:j]))
                i = j
            elif nxt == 'n':
                result += b'\n'; i += 2
            elif nxt == 't':
                result += b'\t'; i += 2
            elif nxt in ('"', "'", '\\'):
                result += nxt.encode('latin-1'); i += 2
            else:
                result += s[i].encode('latin-1'); i += 1
        else:
            result += s[i].encode('utf-8')
            i += 1
    return result.decode('utf-8')

# ── Load Lua ──────────────────────────────────────────────────

lua = LUA_FILE.read_text(encoding='utf-8')
new_lua = lua

# ── SUBTITLES ─────────────────────────────────────────────────

sub_entries = {}  # key -> decoded value
SUB_BODY_RE = re.compile(
    r'(SoilGuideDialog\.SUBTITLES\s*=\s*\{)(.*?)(\n\})',
    re.DOTALL
)
sub_m = SUB_BODY_RE.search(lua)
if not sub_m:
    print("ERROR: could not find SUBTITLES table")
    raise SystemExit(1)

for i, m in enumerate(re.finditer(r'"([^"]*)"', sub_m.group(2)), 1):
    key = f"sf_guide_sub_{i}"
    sub_entries[key] = decode_lua_str(m.group(1))

print(f"Subtitles: {len(sub_entries)} entries")

# Update _selectPage to use tr() for subtitles
old_sub_set = 'self._elSubtitle:setText(SoilGuideDialog.SUBTITLES[n] or "")'
new_sub_set = 'self._elSubtitle:setText(tr("sf_guide_sub_" .. n, SoilGuideDialog.SUBTITLES[n] or ""))'
if old_sub_set in new_lua:
    new_lua = new_lua.replace(old_sub_set, new_sub_set)
    print("Updated _selectPage subtitle call")
else:
    print("WARNING: subtitle setText call not found (already updated?)")

# ── PAGE TABLES ───────────────────────────────────────────────

# Pattern: { t="H"|"B"|"S"|"COL", v="..." }
ENTRY_RE = re.compile(
    r'\{ t="(H|B|S|COL)",\s*v="([^"]*)"\s*\}'
)

PAGE_RE = re.compile(
    r'(SoilGuideDialog\.PAGE(\d)\s*=\s*\{)(.*?)(\n\})',
    re.DOTALL
)

all_page_entries = {}  # key -> decoded value

def make_replacer(page_num):
    counter = [0]
    def replacer(m):
        t = m.group(1)
        raw_v = m.group(2)
        if t in ("H", "B"):
            counter[0] += 1
            key = f"sf_guide_p{page_num}_{counter[0]:02d}"
            decoded_v = decode_lua_str(raw_v)
            all_page_entries[key] = decoded_v
            return f'{{ t="{t}", k="{key}", v="{raw_v}" }}'
        return m.group(0)  # S and COL: unchanged
    return replacer, counter

# Apply page replacements
def process_pages(lua_text):
    result = []
    pos = 0
    for pm in PAGE_RE.finditer(lua_text):
        page_num = int(pm.group(2))
        page_body = pm.group(3)
        replacer, counter = make_replacer(page_num)
        new_body = ENTRY_RE.sub(replacer, page_body)
        print(f"  PAGE{page_num}: {counter[0]} H/B entries keyed")
        # Reconstruct this section
        result.append(lua_text[pos:pm.start(3)])  # up to body start
        result.append(new_body)
        pos = pm.end(3)
    result.append(lua_text[pos:])
    return "".join(result)

print("Processing page tables...")
new_lua = process_pages(new_lua)

# ── _buildContent: use tr() ───────────────────────────────────

old_set = 'el:setText(row.v)'
new_set = 'el:setText(row.k and tr(row.k, row.v or "") or (row.v or ""))'
if old_set in new_lua:
    new_lua = new_lua.replace(old_set, new_set)
    print("Updated _buildContent setText call")
else:
    print("WARNING: _buildContent setText call not found (already updated?)")

# ── Write modified Lua ────────────────────────────────────────

LUA_FILE.write_text(new_lua, encoding='utf-8')
print(f"Wrote {LUA_FILE}")

# ── Build XML entry block ─────────────────────────────────────

all_entries = {}
all_entries.update(sub_entries)
all_entries.update(all_page_entries)

print(f"\nTotal l10n entries: {len(all_entries)}")

xml_lines = []
for key, value in all_entries.items():
    escaped_v = xml_attr(value)
    h = crc32_hex(value)
    xml_lines.append(f'    <e k="{key}" v="{escaped_v}" eh="{h}" />')

xml_block = "\n".join(xml_lines)

# ── Patch all 26 translation files ───────────────────────────

print("\nPatching translation files...")
INSERT_BEFORE = "    </elements>"

for lang in LANGS:
    tf = TRANS_DIR / f"translation_{lang}.xml"
    if not tf.exists():
        print(f"  SKIP {lang}: file not found")
        continue

    content = tf.read_text(encoding='utf-8')

    if "sf_guide_p1_01" in content:
        print(f"  SKIP {lang}: already has guide entries")
        continue

    if INSERT_BEFORE not in content:
        print(f"  WARN {lang}: </elements> marker not found")
        continue

    new_content = content.replace(
        INSERT_BEFORE,
        xml_block + "\n" + INSERT_BEFORE,
        1
    )
    tf.write_text(new_content, encoding='utf-8')
    print(f"  OK   {lang}")

print("\nDone!")
