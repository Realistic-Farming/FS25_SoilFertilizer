import zipfile
import os
import sys
import shutil
from pathlib import Path

# ============================================================
# build.py — Build & deploy FS25_SoilFertilizer
# Usage:
#   python build.py            — builds zip only
#   python build.py --deploy   — builds zip AND copies to mods folder
# ============================================================

MOD_NAME = "FS25_SoilFertilizer"
MOD_DIR = Path(__file__).parent.resolve()
ZIP_PATH = MOD_DIR / f"{MOD_NAME}.zip"

# Windows default mods path
MODS_DIR = Path.home() / "Documents" / "My Games" / "FarmingSimulator2025" / "mods"

EXCLUDE_DIRS = {".git", ".claude", ".github", "__MACOSX", "tools", ".vscode"}
EXCLUDE_EXTS = {".sh", ".py", ".md", ".DS_Store", ".zip"}
EXCLUDE_FILES = {".gitignore", "icon_source.png"}

def build_zip():
    print(f"============================================")
    print(f"  Building {MOD_NAME}")
    print(f"============================================")

    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
        print("  Removed old zip")

    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(MOD_DIR):
            # Filter directories
            dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
            
            for fname in files:
                if fname in EXCLUDE_FILES:
                    continue
                if any(fname.endswith(ext) for ext in EXCLUDE_EXTS):
                    continue
                
                full_path = Path(root) / fname
                arc_name = full_path.relative_to(MOD_DIR).as_posix()
                zf.write(full_path, arc_name)
                print(f"  + {arc_name}")

    print(f"\n  ZIP created: {ZIP_PATH}")

def deploy():
    print(f"\n  Deploying to mods folder...")
    if not MODS_DIR.exists():
        print(f"  WARNING: Mods folder not found at: {MODS_DIR}")
        sys.exit(1)

    dest = MODS_DIR / f"{MOD_NAME}.zip"
    if dest.exists():
        dest.unlink()
    shutil.copy2(ZIP_PATH, dest)
    print(f"  Deployed: {dest}")

if __name__ == "__main__":
    build_zip()
    if "--deploy" in sys.argv:
        deploy()
    print(f"\n  Done. Check log.txt for [SoilFertilizer] entries after launching.")
    print(f"============================================")
