# Field Sentry "sim asleep" on the RF PDA Soil tab: does the bar catch the versions that
# would ship it wrong?
#
#   M1  the status branch dropped            the row shows an urgency for frozen soil again
#   M2  the selected-line append dropped     the plan reads as live advice again
#   M3  the flag read from the wrong key     simDisabledReason is "active" for an awake field,
#                                            so every field reads asleep
#   M4  a raw getText instead of the page tr the l10n gate rule: the key would not go through
#                                            the page's defended translator
#
# Every edit asserts it LANDED by exact occurrence count; restore is proved by sha256.
# "DID NOT APPLY" never counts as a kill.
#
# Run from the repo root:  py tools/test/mutate_sf_pda_asleep_label.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PANEL = "src/ui/RfPdaSoilPanel.lua"

MUTATIONS = [
 ("M1-status-branch-dropped", PANEL,
  [("        if info.simDisabled then\n            -- Field Sentry (#651): a slept field's soil is frozen by intent, so its row",
    "        if false then\n            -- Field Sentry (#651): a slept field's soil is frozen by intent, so its row", 1)],
  "the row shows an urgency for a slept field"),

 ("M2-selected-line-append-dropped", PANEL,
  [("            if info ~= nil and info.simDisabled then\n                local reasonText = info.simDisabledReasonKey",
    "            if false then\n                local reasonText = info.simDisabledReasonKey", 1)],
  "the treatment plan's selected line carries no asleep state"),

 ("M3-flag-read-from-wrong-key", PANEL,
  [("        if info.simDisabled then\n            -- Field Sentry (#651): a slept field's soil is frozen by intent, so its row",
    "        if info.simDisabledReason then\n            -- Field Sentry (#651): a slept field's soil is frozen by intent, so its row", 1)],
  "the reason NAME is read as the flag; it is 'active' for an awake field, so every row reads asleep"),

 ("M4-raw-getText-instead-of-tr", PANEL,
  [("            statusEl:setText(tr(\"sf_fieldsentry_asleep\", \"sim asleep\"))",
    "            statusEl:setText(g_i18n:getText(\"sf_fieldsentry_asleep\"))", 1)],
  "the status cell bypasses the page's defended translator"),
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
