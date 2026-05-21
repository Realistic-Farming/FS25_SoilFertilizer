#!/usr/bin/env bash
# ============================================================
# build.sh — Build & deploy FS25_SoilFertilizer
# Usage:
#   bash build.sh            — builds zip only
#   bash build.sh --deploy   — builds zip AND copies to mods folder
# ============================================================

set -e

MOD_NAME="FS25_SoilFertilizer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/.."
ZIP_PATH="$OUTPUT_DIR/${MOD_NAME}.zip"

MODS_DIR="$USERPROFILE/Documents/My Games/FarmingSimulator2025/mods"

echo "============================================"
echo "  Building $MOD_NAME"
echo "============================================"

if [ -f "$ZIP_PATH" ]; then
    rm "$ZIP_PATH"
    echo "  Removed old zip"
fi

cd "$SCRIPT_DIR"

if command -v zip &>/dev/null; then
    zip -r "$ZIP_PATH" . \
        --exclude "./*.sh" \
        --exclude "./*.py" \
        --exclude "./.claude/*" \
        --exclude "./.claude/**/*" \
        --exclude "./.git/*" \
        --exclude "./.github/*" \
        --exclude "./.github/**/*" \
        --exclude "./*.md" \
        --exclude "./CHANGELOG.md" \
        --exclude "./CONTRIBUTING.md" \
        --exclude "./DEVELOPMENT.md" \
        --exclude "./CLAUDE.md" \
        --exclude "./.gitignore" \
        --exclude "./__MACOSX/*" \
        --exclude "./*.DS_Store" \
        --exclude "./*.zip" \
        --exclude "./tools/*" 
        --exclude "./icon_source.png" \
        --exclude "./config.txt"
    echo "  Built via zip"
else
    PYTHON_CMD=""
    if command -v python3 &>/dev/null; then PYTHON_CMD="python3"
    elif command -v py &>/dev/null; then PYTHON_CMD="py"
    else echo "ERROR: no Python found (need python3 or py)"; exit 1
    fi
    $PYTHON_CMD - <<'PYEOF'
import zipfile, os, sys

MOD_DIR = os.getcwd()
ZIP_PATH = os.path.join(os.path.dirname(MOD_DIR), os.path.basename(MOD_DIR) + ".zip")

EXCLUDE_DIRS  = {".git", ".claude", ".github", "__MACOSX"}
EXCLUDE_EXTS  = {".sh", ".py", ".md", ".DS_Store", ".zip", ".txt"}
EXCLUDE_FILES = {".gitignore", "icon_source.png"}

with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(MOD_DIR):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for fname in files:
            if fname in EXCLUDE_FILES:
                continue
            if any(fname.endswith(ext) for ext in EXCLUDE_EXTS):
                continue
            full_path = os.path.join(root, fname)
            arc_name = os.path.relpath(full_path, MOD_DIR).replace("\\", "/")
            zf.write(full_path, arc_name)
            print(f"  + {arc_name}")

print(f"\n  ZIP created: {ZIP_PATH}")
PYEOF
fi

echo ""
echo "  Output: $ZIP_PATH"

if [[ "$1" == "--deploy" ]]; then
    echo ""
    echo "  Deploying to mods folder..."

    if [ ! -d "$MODS_DIR" ]; then
        echo "  WARNING: Mods folder not found at: $MODS_DIR"
        exit 1
    fi

    rm -f "$MODS_DIR/${MOD_NAME}.zip" || true

    cp "$ZIP_PATH" "$MODS_DIR/${MOD_NAME}.zip"
    echo "  Deployed: $MODS_DIR/${MOD_NAME}.zip"
fi

echo ""
echo "  Done. Check log.txt for [SoilFert] entries after launching."
echo "============================================"
