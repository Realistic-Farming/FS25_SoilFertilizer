#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ==============================================================================
# UNIVERSAL TRANSLATION SYNC TOOL v3.2.2
# For Farming Simulator 25 Mods
# ==============================================================================
#
# WHAT IS THIS?
#   A portable tool that keeps your mod's translation files in sync.
#   Drop this file into your translations folder and run it - that's it!
#
# THE PROBLEM IT SOLVES:
#   When you add or CHANGE a text key in your English file, you need to know
#   which translations need updating. This tool:
#   - Adds missing keys to all language files automatically
#   - Detects when English text changed but translation wasn't updated (STALE)
#   - Uses embedded hashes for self-documenting XML files
#   - Validates translations for data quality issues
#
# QUICK START:
#   cd translations/
#   python lang_sync.py sync      # Sync all languages
#   python lang_sync.py status    # Quick overview
#   python lang_sync.py report    # Detailed breakdown
#   python lang_sync.py help      # Full documentation
#
# HOW HASH-BASED SYNC WORKS:
#   Every entry has an embedded hash (eh) of its English source text:
#
#   English:  <e k="greeting" v="Hello World" eh="a1b2c3d4"/>
#   German:   <e k="greeting" v="Hallo Welt" eh="a1b2c3d4"/>   <- Same hash = OK
#   French:   <e k="greeting" v="Bonjour" eh="99999999"/>     <- Different = STALE!
#
#   When you change English text:
#   1. Run sync - English hash auto-updates
#   2. Target hashes stay the same (they reflect what was translated FROM)
#   3. Hash mismatch = translation is STALE (needs re-translation)
#
#   NOTE: Hash-based stale detection only works with 'elements' format
#         (<e k="" v="" eh=""/>). The 'texts' format (<text name="" text=""/>)
#         does not support embedded hashes but still gets missing/orphan/
#         duplicate/format validation.
#
# COMMANDS:
#   sync      - Add missing keys, update hashes, show what changed
#   status    - Quick table: translated/stale/missing per language
#   report    - Detailed lists of problem keys by language
#   check     - Report issues, exit code 1 if MISSING keys exist
#   validate  - CI-friendly: minimal output, exit codes only
#   help      - Show full help with all options
#
# WHAT IT DETECTS:
#   ✓ Missing keys     - Key in English but not in target language
#   ~ Stale entries    - Hash mismatch (English changed since translation)
#   ? Untranslated     - Has "[EN] " prefix or exact match (excluding cognates)
#   !! Duplicates      - Same key appears twice in file (data corruption!)
#   x Orphaned         - Key in target but NOT in English (safe to delete)
#   💥 Format errors   - Wrong format specifiers (%s, %d, %.1f) - WILL CRASH GAME!
#   ⚠ Empty values    - Translation is empty string
#   ⚠ Whitespace      - Leading/trailing spaces in translation
#
#   NOTE: Cognates and international terms (Type, Status, Generator, OK, etc.)
#         are automatically recognized and NOT flagged as untranslated.
#
# SUPPORTED XML FORMATS (auto-detected):
#   <e k="key" v="value" eh="hash"/>   (elements pattern - hash support)
#   <text name="key" text="value"/>     (texts pattern - no hash support)
#
# SUPPORTED FILE PREFIXES (auto-detected):
#   translation_XX.xml   (e.g., translation_en.xml)
#   l10n_XX.xml          (e.g., l10n_en.xml)
#   lang_XX.xml          (e.g., lang_en.xml)
#
# VERSION HISTORY:
#   v3.2.2 - Added cognate detection (no false positives for international terms)
#          - Added 'lang_' file prefix auto-detection
#   v3.2.1 - Fixed format specifier regex (no false positives on "40% success")
#   v3.2.0 - Added format specifier validation, empty/whitespace detection
#   v3.1.0 - Added duplicate and orphan detection
#   v3.0.0 - Hash-based sync system
#
# Based on: FS25_UsedPlus Translation Sync Tool
# License: MIT - Free to use, modify, and distribute in any mod
# ==============================================================================

import sys
import os
import re
import hashlib
from pathlib import Path

# Windows UTF-8 bootstrap
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except (AttributeError, OSError):
        pass

VERSION = '3.2.2'

# ==============================================================================
# CONFIGURATION
# ==============================================================================

CONFIG = {
    # Source language (the "master" file all others sync from)
    'sourceLanguage': 'en',

    # Prefix added to untranslated entries (so translators know what needs work)
    'untranslatedPrefix': '[EN] ',

    # Automatically remove orphaned keys (not in English source)
    'removeOrphans': True,

    # Automatically trim whitespace from translations
    'trimWhitespace': True,

    # File naming pattern: 'auto', 'translation', 'l10n', or 'lang'
    'filePrefix': 'auto',

    # XML format: 'auto', 'texts', or 'elements'
    'xmlFormat': 'auto',
}

# ==============================================================================
# LANGUAGE NAME MAPPINGS
# ==============================================================================

LANGUAGE_NAMES = {
    'en': 'English',
    'de': 'German',
    'fr': 'French',
    'es': 'Spanish',
    'it': 'Italian',
    'pl': 'Polish',
    'ru': 'Russian',
    'br': 'Portuguese (BR)',
    'pt': 'Portuguese (PT)',
    'cz': 'Czech',
    'cs': 'Chinese (Simplified)',
    'uk': 'Ukrainian',
    'nl': 'Dutch',
    'da': 'Danish',
    'sv': 'Swedish',
    'no': 'Norwegian',
    'fi': 'Finnish',
    'hu': 'Hungarian',
    'ro': 'Romanian',
    'tr': 'Turkish',
    'ja': 'Japanese',
    'jp': 'Japanese',
    'ko': 'Korean',
    'kr': 'Korean',
    'zh': 'Chinese (Simplified)',
    'tw': 'Chinese (Traditional)',
    'ct': 'Chinese (Traditional)',
    'ea': 'Spanish (Latin America)',
    'fc': 'French (Canadian)',
    'id': 'Indonesian',
    'vi': 'Vietnamese',
}

# ==============================================================================
# END OF CONFIGURATION
# ==============================================================================

# Change to script directory
os.chdir(Path(__file__).parent.resolve())

# ------------------------------------------------------------------------------
# Utility Functions
# ------------------------------------------------------------------------------

def get_hash(text):
    """8-character MD5 hash - short but sufficient for change detection."""
    return hashlib.md5(text.encode('utf-8')).hexdigest()[:8]


def escape_regex(s):
    """Escape special regex characters."""
    return re.escape(s)


def escape_xml(s):
    """Escape XML special characters."""
    return (s
        .replace('&', '&amp;')
        .replace('<', '&lt;')
        .replace('>', '&gt;')
        .replace('"', '&quot;'))


def unescape_xml(s):
    """Unescape XML special characters."""
    return (s
        .replace('&amp;', '&')
        .replace('&lt;', '<')
        .replace('&gt;', '>')
        .replace('&quot;', '"'))


# ------------------------------------------------------------------------------
# Validation Functions (v3.2.0)
# ------------------------------------------------------------------------------

def extract_format_specifiers(s):
    """
    Extract format specifiers from a string.
    Matches: %s, %d, %i, %f, %.1f, %.2f, %ld, etc.
    Returns sorted list for comparison.

    NOTE: Excludes space flag to avoid false positives like "40% success"
    where "% s" looks like a specifier but is just a percentage followed by text.
    Real format specifiers don't have space between % and the type letter.
    """
    pattern = r'%[-+0#]*(\d+)?(\.\d+)?(hh?|ll?|L|z|j|t)?[diouxXeEfFgGaAcspn]'
    return sorted(m.group(0) for m in re.finditer(pattern, s))


def check_format_specifiers(source_value, target_value, key):
    """
    Compare format specifiers between source and target.
    Returns None if OK, or dict with error info if mismatch.
    """
    source_specs = extract_format_specifiers(source_value)
    target_specs = extract_format_specifiers(target_value)

    # Quick check: same count?
    if len(source_specs) != len(target_specs):
        return {
            'key': key,
            'type': 'count',
            'source': source_specs,
            'target': target_specs,
            'message': f'Expected {len(source_specs)} format specifier(s), found {len(target_specs)}'
        }

    # Detailed check: same specifiers?
    for i in range(len(source_specs)):
        if source_specs[i] != target_specs[i]:
            return {
                'key': key,
                'type': 'mismatch',
                'source': source_specs,
                'target': target_specs,
                'message': f'Format specifier mismatch: expected "{source_specs[i]}", found "{target_specs[i]}"'
            }

    return None  # OK


def is_format_only_string(value):
    """
    Check if a string is "format-only" (no translatable text content).
    These are strings like "%s %%", "%d km", "%s:%s" that are identical in all languages.
    """
    if not value:
        return False
    stripped = value
    stripped = re.sub(r'%[-+0-9]*\.?[0-9]*[sdfeEgGoxXuc%]', '', stripped)  # format specifiers
    stripped = re.sub(r'\b(km|m|kg|l|h|s|ms|px|pcs)\b', '', stripped, flags=re.IGNORECASE)  # common units
    stripped = re.sub(r'[:\s.,\-/()[\]{}]+', '', stripped)  # punctuation & whitespace
    return len(stripped) == 0


def is_empty_value(value):
    """Check for empty value."""
    return value == '' or value is None


def has_whitespace_issues(value):
    """Check for whitespace issues (leading/trailing)."""
    if not value:
        return False
    return value != value.strip()


def is_cognate_or_international_term(value):
    """
    Check if a value is likely a cognate or international term.
    These are values that are legitimately the same in multiple languages.
    """
    if value == '':
        return True
    if not value:
        return False

    if len(value) > 50:
        return False

    # 1. Very short (1-3 characters)
    if len(value) <= 3:
        return True

    # 2. Contains only symbols, numbers, and punctuation
    if re.match(r'^[#$@%&*()\[\]{}\-+:,./\d\s]+$', value):
        return True

    # 3. Proper names
    if re.match(r'^-\s+[A-Z][a-z]+$', value):
        return True

    # 4. Common single-word cognates and technical terms
    common_cognates = [
        'type', 'total', 'status', 'agent', 'normal', 'ok', 'info', 'mode',
        'generator', 'starter', 'min', 'max', 'per', 'vs', 'hardcore',
        'obd', 'ecu', 'can', 'dtc', 'debug', 'regional', 'national',
        'original', 'score', 'principal', 'ha', 'pcs', 'elite', 'premium',
        'standard', 'budget', 'basic', 'advanced', 'pro', 'master',
        'leasing', 'spawning', 'repo', 'state', 'misfire', 'overheat',
        'runaway', 'cutout', 'workhorse', 'integration', 'vanilla',
        'item', 'land', 'thermostat',
        'description', 'confirmation', 'actions', 'excellent', 'finance', 'finances',
        'acceptable', 'stable', 'ratio'
    ]
    lower_value = value.lower().strip()
    if lower_value in common_cognates:
        return True

    # 5. Common multi-word international phrases
    common_phrases = [
        'regional agent', 'national agent', 'local agent',
        'no', 'yes', 'si', 'ja',
        'obd scanner', 'service truck', 'spawn lemon', 'toggle debug',
        'reset cd'
    ]
    if lower_value in common_phrases:
        return True

    # 6. Phrases with "vs"
    if re.match(r'^vs\s+', value, re.IGNORECASE):
        return True

    # 7. All caps labels
    if re.match(r'^[A-Z\s:]+$', value) and len(re.sub(r'[:\s]', '', value)) >= 2:
        return True

    # 8. Single word ending in colon
    if re.match(r'^[A-Za-z]+:\s*$', value):
        return True

    # 9. Money symbols with amounts
    if re.match(r'^[+\-]?\$[\d,]+$', value) or re.match(r'^Set \$\d+$', value):
        return True

    # 10. Admin labels with percentages or abbreviations
    if re.match(r'^(Rel|Surge|Flat):', value, re.IGNORECASE) or re.search(r'\(L\)$|\(R\)$', value):
        return True

    # 11. Mod integration names
    if re.match(r'^[A-Z]{2,5}\s+Integration$', value, re.IGNORECASE):
        return True

    # 12. Vehicle model names with alphanumerics
    if re.match(r'^[A-Z]+\s+[A-Z0-9\-]+', value, re.IGNORECASE) and len(value.split(' ')) <= 4:
        return True

    return False


def validate_entry(key, source_value, target_value, skip_untranslated=True):
    """
    Validate a translation entry against its source.
    Returns list of issues found.
    """
    issues = []

    if skip_untranslated and target_value.startswith(CONFIG['untranslatedPrefix']):
        return issues

    if is_empty_value(target_value):
        issues.append({'key': key, 'type': 'empty', 'message': 'Empty translation value'})

    if has_whitespace_issues(target_value):
        issues.append({
            'key': key,
            'type': 'whitespace',
            'message': f'Whitespace issue: "{target_value[:20]}..."',
            'value': target_value
        })

    format_issue = check_format_specifiers(source_value, target_value, key)
    if format_issue:
        issues.append(format_issue)

    return issues


def get_enabled_languages():
    """Get list of enabled language files (excluding source language)."""
    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        return []

    pattern = re.compile(r'^' + re.escape(file_prefix) + r'_([a-z]{2})\.xml$', re.IGNORECASE)
    languages = []

    for filename in os.listdir('.'):
        m = pattern.match(filename)
        if m:
            code = m.group(1).lower()
            if code != CONFIG['sourceLanguage']:
                languages.append({
                    'code': code,
                    'name': LANGUAGE_NAMES.get(code, code.upper())
                })

    return sorted(languages, key=lambda x: x['code'])


# ------------------------------------------------------------------------------
# Auto-Detection Functions
# ------------------------------------------------------------------------------

def auto_detect_file_prefix():
    """Auto-detect the file prefix (lang, translation, or l10n)."""
    if CONFIG['filePrefix'] != 'auto':
        return CONFIG['filePrefix']

    src = CONFIG['sourceLanguage']
    if os.path.exists(f'lang_{src}.xml'):
        return 'lang'
    if os.path.exists(f'translation_{src}.xml'):
        return 'translation'
    if os.path.exists(f'l10n_{src}.xml'):
        return 'l10n'

    for filename in os.listdir('.'):
        if re.match(r'^lang_[a-z]{2}\.xml$', filename, re.IGNORECASE):
            return 'lang'
        if re.match(r'^translation_[a-z]{2}\.xml$', filename, re.IGNORECASE):
            return 'translation'
        if re.match(r'^l10n_[a-z]{2}\.xml$', filename, re.IGNORECASE):
            return 'l10n'

    return None


def auto_detect_xml_format(content):
    """Auto-detect the XML format (elements or texts)."""
    if CONFIG['xmlFormat'] != 'auto':
        return CONFIG['xmlFormat']

    if '<e k="' in content:
        return 'elements'
    if '<text name="' in content:
        return 'texts'

    return None


def get_source_file_path(file_prefix):
    return f'{file_prefix}_{CONFIG["sourceLanguage"]}.xml'


def get_lang_file_path(file_prefix, lang_code):
    return f'{file_prefix}_{lang_code}.xml'


# ------------------------------------------------------------------------------
# XML Parsing
# ------------------------------------------------------------------------------

def parse_translation_file(filepath, fmt):
    """
    Parse a translation XML file.
    Returns dict with entries, ordered_keys, duplicates, raw_content.
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    entries = {}
    ordered_keys = []
    duplicates = []

    if fmt == 'elements':
        # <e k="key" v="value" [eh="hash"] [tag="format"] /> - handles any attribute order
        pattern = re.compile(r'<e k="([^"]+)" v="([^"]*)"([^>]*)\s*/>')
    else:
        # <text name="key" text="value"/>
        pattern = re.compile(r'<text name="([^"]+)" text="([^"]*)"\s*/>')

    for m in pattern.finditer(content):
        key = m.group(1)
        value = unescape_xml(m.group(2))
        attrs = m.group(3) if m.lastindex >= 3 else ''
        hash_match = re.search(r'eh="([^"]*)"', attrs)
        entry_hash = hash_match.group(1) if hash_match else None

        if key in entries:
            duplicates.append(key)

        entries[key] = {'value': value, 'hash': entry_hash}
        ordered_keys.append(key)

    return {
        'entries': entries,
        'ordered_keys': ordered_keys,
        'duplicates': duplicates,
        'raw_content': content
    }


def format_entry(key, value, entry_hash, fmt):
    """Generate an XML entry line."""
    escaped_value = escape_xml(value)
    if fmt == 'elements':
        return f'<e k="{key}" v="{escaped_value}" eh="{entry_hash}" />'
    else:
        return f'<text name="{key}" text="{escaped_value}"/>'


def find_insert_position(content, key, en_ordered_keys, lang_keys, fmt):
    """Find the position to insert a new entry, based on predecessor in English ordering."""
    en_index = en_ordered_keys.index(key)

    # Look for the nearest preceding key that exists in this language
    for i in range(en_index - 1, -1, -1):
        prev_key = en_ordered_keys[i]
        if prev_key in lang_keys:
            if fmt == 'elements':
                pattern = re.compile(r'<e k="' + escape_regex(prev_key) + r'" v="[^"]*"(?:[^>]*)\s*/>')
            else:
                pattern = re.compile(r'<text name="' + escape_regex(prev_key) + r'" text="[^"]*"\s*/>')
            m = pattern.search(content)
            if m:
                return m.end()

    # Fallback: insert before closing container tag
    container_tag = 'elements' if fmt == 'elements' else 'texts'
    close_tag_index = content.find(f'</{container_tag}>')
    if close_tag_index != -1:
        return close_tag_index

    return -1


# ------------------------------------------------------------------------------
# Update English Source File with Hashes
# ------------------------------------------------------------------------------

def update_source_hashes(source_file, fmt):
    """Update hashes in the English source file."""
    with open(source_file, 'r', encoding='utf-8') as f:
        content = f.read()

    parsed = parse_translation_file(source_file, fmt)
    entries = parsed['entries']

    updated = 0

    for key, data in entries.items():
        correct_hash = get_hash(data['value'])

        if data['hash'] != correct_hash:
            pattern = re.compile(r'<e k="' + escape_regex(key) + r'" v="([^"]*)"([^>]*)\s*/>')

            def replacer(m):
                v = m.group(1)
                attrs = m.group(2)
                clean_attrs = re.sub(r'\s*eh="[^"]*"', '', attrs)
                has_tag = 'tag="format"' in clean_attrs
                if has_tag:
                    return f'<e k="{key}" v="{v}" eh="{correct_hash}" tag="format"/>'
                else:
                    return f'<e k="{key}" v="{v}" eh="{correct_hash}" />'

            content = pattern.sub(replacer, content)
            updated += 1

    if updated > 0:
        with open(source_file, 'w', encoding='utf-8') as f:
            f.write(content)

    return updated


# ------------------------------------------------------------------------------
# SYNC Command
# ------------------------------------------------------------------------------

def sync_translations():
    print("══════════════════════════════════════════════════════════════════════")
    print(f"TRANSLATION SYNC v{VERSION} - Hash-Based Synchronization")
    print("══════════════════════════════════════════════════════════════════════")
    print()

    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        print("ERROR: Could not find source translation file.", file=sys.stderr)
        print(f'Looking for: lang_{CONFIG["sourceLanguage"]}.xml, translation_{CONFIG["sourceLanguage"]}.xml, or l10n_{CONFIG["sourceLanguage"]}.xml', file=sys.stderr)
        sys.exit(1)

    source_file = get_source_file_path(file_prefix)
    if not os.path.exists(source_file):
        print(f"ERROR: Source file not found: {source_file}", file=sys.stderr)
        sys.exit(1)

    with open(source_file, 'r', encoding='utf-8') as f:
        source_content = f.read()
    fmt = auto_detect_xml_format(source_content)

    if not fmt:
        print("ERROR: Could not detect XML format from source file.", file=sys.stderr)
        sys.exit(1)

    # Step 1: Update hashes in the English source file
    print("[1/3] Updating hashes in source file...")

    if fmt == 'elements':
        hashes_updated = update_source_hashes(source_file, fmt)
        if hashes_updated > 0:
            print(f"      Updated {hashes_updated} hash(es) in {source_file}")
        else:
            print(f"      All hashes current in {source_file}")
    else:
        print("      Skipped (hash embedding only supported for 'elements' format)")

    # Re-parse source after hash update
    parsed = parse_translation_file(source_file, fmt)
    source_entries = parsed['entries']
    source_ordered_keys = parsed['ordered_keys']

    # Compute hashes for comparison
    source_hashes = {}
    for key, data in source_entries.items():
        source_hashes[key] = get_hash(data['value'])

    print()
    print(f"[2/3] Source: {source_file} ({len(source_entries)} keys)")
    no_hash = " (no hash support - stale detection unavailable)" if fmt == 'texts' else ''
    print(f"      Format: {fmt}{no_hash}")
    print()

    # Step 2: Sync to all target languages
    print("[3/3] Syncing to target languages...")
    print()

    enabled_langs = get_enabled_languages()
    results = []

    for lang in enabled_langs:
        lang_code = lang['code']
        lang_name = lang['name']
        lang_file = get_lang_file_path(file_prefix, lang_code)

        if not os.path.exists(lang_file):
            print(f"  {lang_name:<18}: FILE NOT FOUND - skipping")
            results.append({'lang': lang_name, 'missing': -1, 'stale': 0, 'added': 0})
            continue

        parsed = parse_translation_file(lang_file, fmt)
        lang_entries = parsed['entries']
        lang_keys = parsed['ordered_keys']
        lang_duplicates = parsed['duplicates']
        content = parsed['raw_content']
        lang_key_set = set(lang_keys)

        missing = []
        stale = []
        duplicates = lang_duplicates or []
        orphaned = []
        format_errors = []
        empty_values = []
        whitespace_issues = []
        added = 0

        # Find missing and stale keys (source -> target)
        for source_key in source_ordered_keys:
            source_hash = source_hashes[source_key]

            if source_key not in lang_entries:
                missing.append(source_key)
            elif fmt == 'elements':
                lang_data = lang_entries[source_key]
                if lang_data['hash'] != source_hash and not lang_data['value'].startswith(CONFIG['untranslatedPrefix']):
                    stale.append(source_key)

        # Find orphaned keys (in target but NOT in source)
        for lang_key in lang_keys:
            if lang_key not in source_entries:
                orphaned.append(lang_key)

        # Validate translations for format specifiers, empty values, whitespace
        for key, source_data in source_entries.items():
            if key in lang_entries:
                lang_data = lang_entries[key]
                validation_issues = validate_entry(key, source_data['value'], lang_data['value'])

                for issue in validation_issues:
                    if issue['type'] in ('count', 'mismatch'):
                        format_errors.append(issue)
                    elif issue['type'] == 'empty':
                        empty_values.append(issue)
                    elif issue['type'] == 'whitespace':
                        whitespace_issues.append(issue)

        # Add missing keys
        for key in missing:
            source_data = source_entries[key]
            source_hash = source_hashes[key]
            placeholder_value = CONFIG['untranslatedPrefix'] + source_data['value']
            new_entry = '\n\t\t' + format_entry(key, placeholder_value, source_hash, fmt)

            insert_pos = find_insert_position(content, key, source_ordered_keys, lang_key_set, fmt)

            if insert_pos != -1:
                content = content[:insert_pos] + new_entry + content[insert_pos:]
                lang_key_set.add(key)
                added += 1

        # Update stale entries to [EN] + English value
        for key in stale:
            source_data = source_entries[key]
            source_hash = source_hashes[key]
            placeholder_value = CONFIG['untranslatedPrefix'] + source_data['value']

            if fmt == 'elements':
                pattern = re.compile(r'<e k="' + escape_regex(key) + r'" v="([^"]*)"([^>]*)\s*/>')
            else:
                pattern = re.compile(r'<text name="' + escape_regex(key) + r'" text="[^"]*"\s*/>')

            def make_replacer(k, v, sh):
                def replacer(m):
                    if fmt == 'elements':
                        attrs = m.group(2)
                        clean_attrs = re.sub(r'\s*eh="[^"]*"', '', attrs)
                        has_tag = 'tag="format"' in clean_attrs
                        if has_tag:
                            return f'<e k="{k}" v="{escape_xml(v)}" eh="{sh}" tag="format"/>'
                        else:
                            return f'<e k="{k}" v="{escape_xml(v)}" eh="{sh}" />'
                    else:
                        return f'<text name="{k}" text="{escape_xml(v)}"/>'
                return replacer

            content = pattern.sub(make_replacer(key, placeholder_value, source_hash), content)

        # Remove orphaned keys
        if CONFIG.get('removeOrphans') and orphaned:
            for key in orphaned:
                if fmt == 'elements':
                    pattern = re.compile(r'\n?\s*<e k="' + escape_regex(key) + r'" v="[^"]*"(?:[^>]*)\s*/>')
                else:
                    pattern = re.compile(r'\n?\s*<text name="' + escape_regex(key) + r'" text="[^"]*"\s*/>')
                content = pattern.sub('', content)

        # Remove duplicates (keep first)
        if duplicates:
            for key in duplicates:
                if fmt == 'elements':
                    pattern = re.compile(r'\n?\s*<e k="' + escape_regex(key) + r'" v="[^"]*"(?:[^>]*)\s*/>')
                else:
                    pattern = re.compile(r'\n?\s*<text name="' + escape_regex(key) + r'" text="[^"]*"\s*/>')
                
                matches = list(pattern.finditer(content))
                if len(matches) > 1:
                    # Remove all but the first one
                    for m in reversed(matches[1:]):
                        content = content[:m.start()] + content[m.end():]

        # Trim whitespace
        if CONFIG.get('trimWhitespace') and whitespace_issues:
            for issue in whitespace_issues:
                key = issue['key']
                val = issue['value'].strip()
                if fmt == 'elements':
                    pattern = re.compile(r'(<e k="' + escape_regex(key) + r'" v=")[^"]*("([^>]*)\s*/>)')
                    content = pattern.sub(r'\1' + escape_xml(val) + r'\2', content)
                else:
                    pattern = re.compile(r'(<text name="' + escape_regex(key) + r'" text=")[^"]*("\s*/>)')
                    content = pattern.sub(r'\1' + escape_xml(val) + r'\2', content)

        # Update hashes for existing entries to match source (elements format only)
        if fmt == 'elements':
            for key, source_data in source_entries.items():
                if key in lang_entries and key not in missing and key not in stale:
                    source_hash = source_hashes[key]
                    lang_data = lang_entries[key]

                    has_no_hash = not lang_data['hash']
                    is_untranslated = lang_data['value'].startswith(CONFIG['untranslatedPrefix'])
                    should_add_hash = (has_no_hash and not is_untranslated)

                    if should_add_hash:
                        pattern = re.compile(r'<e k="' + escape_regex(key) + r'" v="([^"]*)"([^>]*)\s*/>')

                        def make_replacer(k, sh):
                            def replacer(m):
                                v = m.group(1)
                                attrs = m.group(2)
                                clean_attrs = re.sub(r'\s*eh="[^"]*"', '', attrs)
                                has_tag = 'tag="format"' in clean_attrs
                                if has_tag:
                                    return f'<e k="{k}" v="{v}" eh="{sh}" tag="format"/>'
                                else:
                                    return f'<e k="{k}" v="{v}" eh="{sh}" />'
                            return replacer

                        content = pattern.sub(make_replacer(key, source_hash), content)

        with open(lang_file, 'w', encoding='utf-8') as f:
            f.write(content)

        # Report
        issues = []
        if added > 0:
            issues.append(f'+{added} added')
        if len(stale) > 0:
            issues.append(f'{len(stale)} stale')
        if len(duplicates) > 0:
            issues.append(f'{len(duplicates)} duplicates')
        if len(orphaned) > 0:
            issues.append(f'{len(orphaned)} orphaned')
        if len(format_errors) > 0:
            issues.append(f'{len(format_errors)} FORMAT ERRORS')
        if len(empty_values) > 0:
            issues.append(f'{len(empty_values)} empty')
        if len(whitespace_issues) > 0:
            issues.append(f'{len(whitespace_issues)} whitespace')

        if len(issues) == 0:
            print(f'  {lang_name:<18}: \u2713 OK')
        else:
            print(f'  {lang_name:<18}: {", ".join(issues)}')

            if len(format_errors) > 0:
                print('    \U0001f534 FORMAT SPECIFIER ERRORS (will crash game!):')
                for err in format_errors[:5]:
                    print(f'    \U0001f4a5 {err["key"]}: {err["message"]}')
                if len(format_errors) > 5:
                    print(f'    ... and {len(format_errors) - 5} more format errors')

            if added > 0:
                for key in missing[:3]:
                    print(f'    + {key}')
                if len(missing) > 3:
                    print(f'    ... and {len(missing) - 3} more')

            if 0 < len(stale) <= 5:
                print('    Stale (English changed):')
                for key in stale:
                    print(f'    ~ {key}')
            elif len(stale) > 5:
                print(f'    Stale: {", ".join(stale[:3])} ... +{len(stale) - 3} more')

            if 0 < len(duplicates) <= 5:
                print('    Duplicates (same key appears twice - remove one!):')
                for key in duplicates:
                    print(f'    !! {key}')
            elif len(duplicates) > 5:
                print(f'    Duplicates: {", ".join(duplicates[:3])} ... +{len(duplicates) - 3} more')

            if 0 < len(orphaned) <= 5:
                print('    Orphaned (not in English - can delete):')
                for key in orphaned:
                    print(f'    x {key}')
            elif len(orphaned) > 5:
                print(f'    Orphaned: {", ".join(orphaned[:3])} ... +{len(orphaned) - 3} more')

            if len(empty_values) > 0:
                keys_str = ', '.join(e['key'] for e in empty_values[:3])
                more = f' ... +{len(empty_values) - 3} more' if len(empty_values) > 3 else ''
                print(f'    Empty values: {keys_str}{more}')
            if len(whitespace_issues) > 0:
                keys_str = ', '.join(e['key'] for e in whitespace_issues[:3])
                more = f' ... +{len(whitespace_issues) - 3} more' if len(whitespace_issues) > 3 else ''
                print(f'    Whitespace issues: {keys_str}{more}')

        results.append({
            'lang': lang_name,
            'missing': len(missing),
            'stale': len(stale),
            'duplicates': len(duplicates),
            'orphaned': len(orphaned),
            'formatErrors': len(format_errors),
            'emptyValues': len(empty_values),
            'whitespaceIssues': len(whitespace_issues),
            'added': added
        })

    print()
    print("══════════════════════════════════════════════════════════════════════")
    print("SYNC COMPLETE")
    print()
    if fmt == 'elements':
        print("Hash-based tracking is now embedded in your XML files:")
        print('  - English entries have eh="hash" showing current text hash')
        print('  - Target entries have eh="hash" showing what they were translated from')
        print("  - When hashes don't match = translation is STALE (needs update)")
    else:
        print("Using 'texts' XML format (no hash embedding).")
        print("Missing keys, duplicates, orphans, and format errors are detected.")
        print("For stale detection, consider migrating to 'elements' format.")
    print()
    print(f'New entries have "{CONFIG["untranslatedPrefix"]}" prefix - they need translation!')
    print("══════════════════════════════════════════════════════════════════════")


# ------------------------------------------------------------------------------
# CHECK Command
# ------------------------------------------------------------------------------

def check_sync():
    print("══════════════════════════════════════════════════════════════════════")
    print(f"TRANSLATION CHECK v{VERSION}")
    print("══════════════════════════════════════════════════════════════════════")
    print()

    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        print("ERROR: Could not find source translation file.", file=sys.stderr)
        sys.exit(1)

    source_file = get_source_file_path(file_prefix)
    if not os.path.exists(source_file):
        print(f"ERROR: Source file not found: {source_file}", file=sys.stderr)
        sys.exit(1)

    with open(source_file, 'r', encoding='utf-8') as f:
        source_content = f.read()
    fmt = auto_detect_xml_format(source_content)
    parsed = parse_translation_file(source_file, fmt)
    source_entries = parsed['entries']

    source_hashes = {}
    for key, data in source_entries.items():
        source_hashes[key] = get_hash(data['value'])

    print(f"Source: {source_file} ({len(source_entries)} keys)\n")

    has_problems = False
    summary = []
    enabled_langs = get_enabled_languages()

    for lang in enabled_langs:
        lang_code = lang['code']
        lang_name = lang['name']
        lang_file = get_lang_file_path(file_prefix, lang_code)

        if not os.path.exists(lang_file):
            print(f"  {lang_name:<18}: FILE NOT FOUND")
            has_problems = True
            summary.append({'name': lang_name, 'total': 0, 'missing': -1, 'stale': 0, 'untranslated': 0})
            continue

        parsed = parse_translation_file(lang_file, fmt)
        lang_entries = parsed['entries']
        lang_keys = parsed['ordered_keys']
        lang_duplicates = parsed['duplicates']

        missing = []
        stale = []
        untranslated = []
        duplicates = lang_duplicates or []
        orphaned = []

        for key, source_data in source_entries.items():
            source_hash = source_hashes[key]

            if key not in lang_entries:
                missing.append(key)
            else:
                lang_data = lang_entries[key]

                if lang_data['value'].startswith(CONFIG['untranslatedPrefix']):
                    untranslated.append(key)
                elif lang_data['value'] == source_data['value'] and not is_format_only_string(source_data['value']) and not is_cognate_or_international_term(source_data['value']):
                    untranslated.append(key)
                elif fmt == 'elements' and lang_data['hash'] and lang_data['hash'] != source_hash:
                    stale.append(key)

        for lang_key in lang_keys:
            if lang_key not in source_entries:
                orphaned.append(lang_key)

        issues = []
        if len(missing) > 0:
            issues.append(f'{len(missing)} MISSING')
        if len(stale) > 0:
            issues.append(f'{len(stale)} stale')
        if len(untranslated) > 0:
            issues.append(f'{len(untranslated)} untranslated')
        if len(duplicates) > 0:
            issues.append(f'{len(duplicates)} duplicates')
        if len(orphaned) > 0:
            issues.append(f'{len(orphaned)} orphaned')

        if len(issues) == 0:
            print(f'  {lang_name:<18}: \u2713 OK ({len(lang_entries)} keys)')
        else:
            if len(missing) > 0 or len(duplicates) > 0 or len(orphaned) > 0:
                has_problems = True
            print(f'  {lang_name:<18}: {", ".join(issues)}')

        summary.append({
            'name': lang_name,
            'total': len(lang_entries),
            'missing': len(missing),
            'stale': len(stale),
            'untranslated': len(untranslated),
            'duplicates': len(duplicates),
            'orphaned': len(orphaned)
        })

    print()
    print("\u2500" * 98)
    print("SUMMARY:")
    print("\u2500" * 98)
    print("Language            | Total  | Missing | Stale | Untranslated | Duplicates | Orphaned")
    print("\u2500" * 98)

    for s in summary:
        status = '!!' if (s['missing'] > 0 or s.get('duplicates', 0) > 0 or s.get('orphaned', 0) > 0) else '  '
        total_str = '  N/A' if s['missing'] == -1 else str(s['total']).rjust(6)
        missing_str = '  N/A' if s['missing'] == -1 else str(s['missing']).rjust(7)
        dups_str = str(s.get('duplicates', 0)).rjust(10) if s.get('duplicates') is not None else '       N/A'
        orph_str = str(s.get('orphaned', 0)).rjust(8) if s.get('orphaned') is not None else '     N/A'
        print(f'{status}{s["name"]:<18} | {total_str} | {missing_str} | {str(s["stale"]).rjust(5)} | {str(s["untranslated"]).rjust(12)} | {dups_str} | {orph_str}')

    print("\u2500" * 98)

    if has_problems:
        print()
        total_missing = sum(s['missing'] for s in summary if s['missing'] > 0)
        total_duplicates = sum(s.get('duplicates', 0) for s in summary)
        total_orphaned = sum(s.get('orphaned', 0) for s in summary)
        if total_missing > 0:
            print("CRITICAL: Missing keys detected! Run 'python lang_sync.py sync' to fix.")
        if total_duplicates > 0:
            print(f"CRITICAL: {total_duplicates} duplicate keys found! Manually remove duplicate entries from XML files.")
        if total_orphaned > 0:
            print(f"WARNING: {total_orphaned} orphaned keys found (in target but not in English). Safe to delete.")
        sys.exit(1)
    else:
        print()
        total_stale = sum(s['stale'] for s in summary)
        total_untranslated = sum(s['untranslated'] for s in summary)

        if total_stale > 0:
            print(f"Note: {total_stale} stale entries need re-translation (English text changed).")
        if total_untranslated > 0:
            print(f'Note: {total_untranslated} entries have "{CONFIG["untranslatedPrefix"]}" prefix and need translation.')
        if total_stale == 0 and total_untranslated == 0:
            print("All translations are complete and up to date!")
        sys.exit(0)


# ------------------------------------------------------------------------------
# STATUS Command
# ------------------------------------------------------------------------------

def show_status():
    print()
    print("══════════════════════════════════════════════════════════════════════")
    print(f"TRANSLATION STATUS v{VERSION}")
    print("══════════════════════════════════════════════════════════════════════")
    print()

    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        print("ERROR: Could not find translation files.", file=sys.stderr)
        sys.exit(1)

    source_file = get_source_file_path(file_prefix)
    with open(source_file, 'r', encoding='utf-8') as f:
        source_content = f.read()
    fmt = auto_detect_xml_format(source_content)
    parsed = parse_translation_file(source_file, fmt)
    source_entries = parsed['entries']

    source_hashes = {}
    for key, data in source_entries.items():
        source_hashes[key] = get_hash(data['value'])

    print(f"Source: {source_file} ({len(source_entries)} keys)")
    hash_label = ' (hash-enabled)' if fmt == 'elements' else ' (no hash support)'
    print(f"Format: {fmt}{hash_label}")
    print()

    print("Language            | Translated |  Stale  | Untranslated | Missing | Dups | Orphaned")
    print("\u2500" * 90)

    enabled_langs = get_enabled_languages()

    for lang in enabled_langs:
        lang_code = lang['code']
        lang_name = lang['name']
        lang_file = get_lang_file_path(file_prefix, lang_code)

        if not os.path.exists(lang_file):
            print(f"{lang_name:<20}|    N/A     |   N/A   |     N/A      |   N/A   |  N/A |    N/A")
            continue

        parsed = parse_translation_file(lang_file, fmt)
        lang_entries = parsed['entries']
        lang_keys = parsed['ordered_keys']
        lang_duplicates = parsed['duplicates']

        translated = 0
        stale = 0
        untranslated_count = 0
        missing = 0
        orphaned = 0
        format_errs = 0
        duplicates = len(lang_duplicates) if lang_duplicates else 0

        for key, source_data in source_entries.items():
            source_hash = source_hashes[key]

            if key not in lang_entries:
                missing += 1
            else:
                lang_data = lang_entries[key]

                if lang_data['value'].startswith(CONFIG['untranslatedPrefix']):
                    untranslated_count += 1
                elif lang_data['value'] == source_data['value'] and not is_format_only_string(source_data['value']) and not is_cognate_or_international_term(source_data['value']):
                    untranslated_count += 1
                elif fmt == 'elements' and lang_data['hash'] and lang_data['hash'] != source_hash:
                    stale += 1
                else:
                    translated += 1

                format_issue = check_format_specifiers(source_data['value'], lang_data['value'], key)
                if format_issue and not lang_data['value'].startswith(CONFIG['untranslatedPrefix']):
                    format_errs += 1

        for lang_key in lang_keys:
            if lang_key not in source_entries:
                orphaned += 1

        fmt_str = f' \U0001f534{format_errs}' if format_errs > 0 else ''
        print(f"{lang_name:<20}| {str(translated).rjust(10)} | {str(stale).rjust(7)} | {str(untranslated_count).rjust(12)} | {str(missing).rjust(7)} | {str(duplicates).rjust(4)} | {str(orphaned).rjust(8)}{fmt_str}")

    print("\u2500" * 90)
    print("\U0001f534 = Format specifier errors (CRITICAL - will crash game!)")


# ------------------------------------------------------------------------------
# REPORT Command
# ------------------------------------------------------------------------------

def generate_report():
    print("══════════════════════════════════════════════════════════════════════")
    print(f"TRANSLATION DETAILED REPORT v{VERSION}")
    print("══════════════════════════════════════════════════════════════════════")
    print()

    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        print("ERROR: Could not find source translation file.", file=sys.stderr)
        sys.exit(1)

    source_file = get_source_file_path(file_prefix)
    with open(source_file, 'r', encoding='utf-8') as f:
        source_content = f.read()
    fmt = auto_detect_xml_format(source_content)
    parsed = parse_translation_file(source_file, fmt)
    source_entries = parsed['entries']

    source_hashes = {}
    for key, data in source_entries.items():
        source_hashes[key] = get_hash(data['value'])

    print(f"Source: {source_file} ({len(source_entries)} keys)\n")

    enabled_langs = get_enabled_languages()

    for lang in enabled_langs:
        lang_code = lang['code']
        lang_name = lang['name']
        lang_file = get_lang_file_path(file_prefix, lang_code)

        if not os.path.exists(lang_file):
            print(f"{lang_name} ({lang_code.upper()}): FILE NOT FOUND\n")
            continue

        parsed = parse_translation_file(lang_file, fmt)
        lang_entries = parsed['entries']
        lang_keys = parsed['ordered_keys']
        lang_duplicates = parsed['duplicates']

        translated = []
        missing = []
        stale = []
        untranslated_list = []
        duplicates = lang_duplicates or []
        orphaned = []

        for key, source_data in source_entries.items():
            source_hash = source_hashes[key]

            if key not in lang_entries:
                missing.append({'key': key, 'enValue': source_data['value']})
            else:
                lang_data = lang_entries[key]

                if lang_data['value'].startswith(CONFIG['untranslatedPrefix']):
                    untranslated_list.append({'key': key, 'reason': 'has [EN] prefix'})
                elif lang_data['value'] == source_data['value'] and not is_format_only_string(source_data['value']) and not is_cognate_or_international_term(source_data['value']):
                    untranslated_list.append({'key': key, 'reason': 'exact match (not cognate)'})
                elif fmt == 'elements' and lang_data['hash'] and lang_data['hash'] != source_hash:
                    stale.append({
                        'key': key,
                        'oldHash': lang_data['hash'],
                        'newHash': source_hash,
                        'enValue': source_data['value']
                    })
                else:
                    translated.append(key)

        for lang_key in lang_keys:
            if lang_key not in source_entries:
                orphaned.append(lang_key)

        print("\u2501" * 74)
        print(f"{lang_name} ({lang_code.upper()})")
        print("\u2501" * 74)
        print(f"  Translated:    {len(translated)}")
        print(f"  Missing:       {len(missing)}")
        print(f"  Stale:         {len(stale)}")
        print(f"  Untranslated:  {len(untranslated_list)}")
        print(f"  Duplicates:    {len(duplicates)}")
        print(f"  Orphaned:      {len(orphaned)}")

        if len(missing) > 0:
            print(f"\n  \u2500\u2500 MISSING KEYS \u2500\u2500")
            for item in missing[:10]:
                print(f"    - {item['key']}")
            if len(missing) > 10:
                print(f"    ... and {len(missing) - 10} more")

        if len(stale) > 0:
            print(f"\n  \u2500\u2500 STALE (English changed since translation) \u2500\u2500")
            for item in stale[:10]:
                print(f"    ~ {item['key']}  ({item['oldHash']} \u2192 {item['newHash']})")
            if len(stale) > 10:
                print(f"    ... and {len(stale) - 10} more")

        if 0 < len(untranslated_list) <= 10:
            print(f"\n  \u2500\u2500 UNTRANSLATED \u2500\u2500")
            for item in untranslated_list:
                print(f"    ? {item['key']}  ({item['reason']})")
        elif len(untranslated_list) > 10:
            print(f"\n  \u2500\u2500 UNTRANSLATED (showing first 10) \u2500\u2500")
            for item in untranslated_list[:10]:
                print(f"    ? {item['key']}  ({item['reason']})")
            print(f"    ... and {len(untranslated_list) - 10} more")

        if 0 < len(duplicates) <= 10:
            print(f"\n  \u2500\u2500 DUPLICATES (same key appears twice - remove one!) \u2500\u2500")
            for key in duplicates:
                print(f"    !! {key}")
        elif len(duplicates) > 10:
            print(f"\n  \u2500\u2500 DUPLICATES (showing first 10) \u2500\u2500")
            for key in duplicates[:10]:
                print(f"    !! {key}")
            print(f"    ... and {len(duplicates) - 10} more")

        if 0 < len(orphaned) <= 10:
            print(f"\n  \u2500\u2500 ORPHANED (not in English - safe to delete) \u2500\u2500")
            for key in orphaned:
                print(f"    x {key}")
        elif len(orphaned) > 10:
            print(f"\n  \u2500\u2500 ORPHANED (showing first 10) \u2500\u2500")
            for key in orphaned[:10]:
                print(f"    x {key}")
            print(f"    ... and {len(orphaned) - 10} more")

        print()

    print("══════════════════════════════════════════════════════════════════════")


# ------------------------------------------------------------------------------
# VALIDATE Command (CI-friendly)
# ------------------------------------------------------------------------------

def validate_sync():
    file_prefix = auto_detect_file_prefix()
    if not file_prefix:
        print("FAIL: No translation files found")
        sys.exit(1)

    source_file = get_source_file_path(file_prefix)
    if not os.path.exists(source_file):
        print("FAIL: Source file not found")
        sys.exit(1)

    with open(source_file, 'r', encoding='utf-8') as f:
        source_content = f.read()
    fmt = auto_detect_xml_format(source_content)
    parsed = parse_translation_file(source_file, fmt)
    source_entries = parsed['entries']

    has_problems = False
    enabled_langs = get_enabled_languages()

    for lang in enabled_langs:
        lang_code = lang['code']
        lang_file = get_lang_file_path(file_prefix, lang_code)
        if not os.path.exists(lang_file):
            has_problems = True
            break

        parsed = parse_translation_file(lang_file, fmt)
        lang_entries = parsed['entries']

        for key in source_entries:
            if key not in lang_entries:
                has_problems = True
                break

        if has_problems:
            break

    if has_problems:
        print("FAIL: Translation files out of sync")
        sys.exit(1)
    else:
        print("OK: All translation files have required keys")
        sys.exit(0)


# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------

def show_help():
    print(f"""
══════════════════════════════════════════════════════════════════════════════
UNIVERSAL TRANSLATION SYNC TOOL v{VERSION}
══════════════════════════════════════════════════════════════════════════════

A translation synchronization tool for Farming Simulator 25 mods.
Supports hash-based stale detection (elements format) and key sync (all formats).

COMMANDS:
  sync      - Add missing keys, update source hashes, report stale entries
  check     - Report all issues, exit code 1 if MISSING keys exist
  status    - Quick overview: translated/stale/missing per language
  report    - Detailed breakdown by language with lists of problem keys
  validate  - CI-friendly: minimal output, exit codes only
  help      - Show this help

USAGE:
  python lang_sync.py sync     # Sync all languages, add missing keys
  python lang_sync.py check    # Verify sync status
  python lang_sync.py status   # Quick overview table
  python lang_sync.py report   # See detailed stale/missing lists

SUPPORTED FILE PATTERNS (auto-detected):
  lang_XX.xml          (e.g., lang_en.xml - used by FS25_NPCFavor)
  translation_XX.xml   (e.g., translation_en.xml)
  l10n_XX.xml          (e.g., l10n_en.xml)

SUPPORTED XML FORMATS (auto-detected):
  <text name="key" text="value"/>     (texts format - key sync only)
  <e k="key" v="value" eh="hash"/>   (elements format - full hash tracking)

STATUS MEANINGS:
  \u2713 Translated   - Entry exists (and hash matches, if applicable)
  ~ Stale        - Hash mismatch (English changed since translation)
  ? Untranslated - Has "[EN] " prefix or exact match to English
  - Missing      - Key doesn't exist in target file
  !! Duplicate   - Same key appears more than once (data quality issue!)
  x Orphaned     - Key in target file but NOT in English (safe to delete)

VALIDATION:
  \U0001f4a5 Format Error  - Missing/wrong format specifiers (%s, %.1f, etc.) - WILL CRASH!
  \u26a0 Empty Value   - Translation is empty string
  \u26a0 Whitespace    - Leading/trailing spaces in translation

══════════════════════════════════════════════════════════════════════════════
""")


# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

def main():
    command = sys.argv[1].lower() if len(sys.argv) > 1 else None

    if command == 'sync':
        sync_translations()
    elif command == 'check':
        check_sync()
    elif command == 'status':
        show_status()
    elif command == 'report':
        generate_report()
    elif command == 'validate':
        validate_sync()
    elif command in ('help', '--help', '-h'):
        show_help()
    else:
        show_help()


if __name__ == '__main__':
    main()
