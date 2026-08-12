import io
import os
path = "translations/translation_en.xml"
with io.open(path, "r", encoding="utf-8") as f:
    content = f.read()
new_keys = u"""    <e k="sf_multi_tank_short"             v="Multi-Tank Application" />
    <e k="sf_multi_tank_long"              v="Apply fertilizer to multiple tanks at once (dual tanks, front + rear)" />
    <e k="sf_desc_multiTankApplication"   v="When enabled, applying product also fills or drains secondary tanks proportionally" />
"""
marker = "</elements>"
if marker in content and "sf_multi_tank_short" not in content:
    content = content.replace(marker, new_keys + marker)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print("OK")
else:
    print("SKIP")