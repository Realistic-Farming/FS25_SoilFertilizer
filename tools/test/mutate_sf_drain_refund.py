# Drain Vehicle refund basis (Tyson's ruling 2026-09-23): does the bar catch the versions
# that would ship it wrong?
#
# Five mutants, each must send RSF-F196-r7_drain_vehicle_test.lua RED by a NAMED row:
#
#   M1  the command's own price table restored     the XML price is ignored again
#   M2  the 50% dropped                             the refund is the full shop price
#   M3  a captured price instead of the manager     a redefined product keeps the first price seen
#   M4  an unpriced product refunds at 1.0/L        the old fallback rule for a product with no economy
#   M5  the "no shop price" report suffix dropped   a zero refund is not explained
#
# Every edit asserts it LANDED by exact occurrence count; restore is proved by sha256.
# "DID NOT APPLY" never counts as a kill.
#
# Run from the repo root:  py tools/test/mutate_sf_drain_refund.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GUI = "src/settings/SoilSettingsGUI.lua"

READ = "            priceTable[idx] = shopPricePerLiter(idx)\n"
REFUND = "                        refund  = drained * priceTable[currentType] * 0.5\n"
GUARD = "        if price == nil or price ~= price or price == math.huge or price < 0 then return 0 end\n"
SUFFIX = "                            unpriced and \" (no shop price, refund 0)\" or \"\",\n"

MUTATIONS = [
 ("M1-own-price-table-restored", GUI,
  [(READ, "            priceTable[idx] = ({ UREA=1.65, AMS=1.40, GYPSUM=0.80, STARTER=1.70, LIQUID_UREA=1.70 })[name] or 1.0\n", 1)],
  "the command carries its own price table again and the fillTypes.xml price is ignored"),

 ("M2-half-dropped", GUI,
  [(REFUND, "                        refund  = drained * priceTable[currentType]\n", 1)],
  "the refund is the full shop price, not 50%"),

 ("M3-captured-price-not-manager", GUI,
  [(READ, "            SoilSettingsGUI._drainPriceCache = SoilSettingsGUI._drainPriceCache or {}\n"
          "            if SoilSettingsGUI._drainPriceCache[idx] == nil then SoilSettingsGUI._drainPriceCache[idx] = shopPricePerLiter(idx) end\n"
          "            priceTable[idx] = SoilSettingsGUI._drainPriceCache[idx]\n", 1)],
  "the price is captured on first use, so a map or mod that redefines a product is not honoured"),

 ("M4-unpriced-refunds-at-one", GUI,
  [(GUARD, "        if price == nil or price ~= price or price == math.huge or price <= 0 then return 1.0 end\n", 1)],
  "a product with no shop price refunds at 1.0/L, the old fallback rule"),

 ("M5-no-shop-price-suffix-dropped", GUI,
  [(SUFFIX, "                            \"\",\n", 1)],
  "a zero refund on an unpriced product is not explained in the report"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s" % (tag, mid))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
