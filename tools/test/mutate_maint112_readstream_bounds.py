# MAINTENANCE row 112 mutation battery: the wrong-side early return on the eight server-to-client
# readStreams and the count bounds (fields, buffers, zone cells, chunk rows, row shape, run length,
# mask entries), all in src/network/NetworkEvents.lua. Rows live in
# MAINT-112-readstream_bounds_spec_test.lua; the other bars run with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the batch WRITER's cap (SF_ZONE_SYNC_MAX in the writer): the reader's bound is the same
#   name, so a writer-only change has no row that could see it; the writer's cap is the
#   round-trip suite's subject.
# - the checksum count: a UInt8 the reader already cannot exceed 255 on; not bounded here.
# - the bands count: ResistanceBands.readStream caps at MAX_WIRE_BANDS already.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_maint112_readstream_bounds.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NE = "src/network/NetworkEvents.lua"
WRONG = '    if not sfAppliesOnClient(connection) then self.refused = "WRONG_SIDE" return end\n'

def early(fn, first):
    return [("function " + fn + "(streamId, connection)\n" + WRONG + first,
             "function " + fn + "(streamId, connection)\n" + first, 1)]

MUTATIONS = [
 ("S1-no-addupdateable-not-batched", NE,
  [("    if isDedicatedServer or not canDrip then\n", "    if isDedicatedServer then\n", 1)],
  "with no addUpdateable the full sync no longer takes the batched path (MAINTENANCE row 120)"),
 # ── the wrong side reads nothing, one event at a time ───────────────────────
 ("E1-setting-sync-reads-on-the-host", NE, early("SoilSettingSyncEvent:readStream", "    self.settingName = streamReadString(streamId)\n"), "the host reads a client's setting sync"),
 ("E2-full-sync-reads-on-the-host", NE, early("SoilFullSyncEvent:readStream", "    self.settings = {}\n"), "the host reads a client's full sync"),
 ("E3-batch-reads-on-the-host", NE, early("SoilFieldBatchSyncEvent:readStream", "    local count  = streamReadInt32(streamId)\n"), "the host reads a client's field batch"),
 ("E4-update-reads-on-the-host", NE, early("SoilFieldUpdateEvent:readStream", "    self.fieldId = streamReadInt32(streamId)\n"), "the host reads a client's field update"),
 ("E5-sentry-status-reads-on-the-host", NE, early("SoilFieldSentryStatusEvent:readStream", "    self.fieldId = streamReadInt32(streamId)\n"), "the host reads a client's sentry status"),
 ("E6-chunk-reads-on-the-host", NE, early("SoilValueMapChunkEvent:readStream", "    self.layerIdx = streamReadUInt8(streamId)\n"), "the host reads a client's value-map chunk"),
 ("E7-checksum-reads-on-the-host", NE, early("SoilValueMapChecksumEvent:readStream", "    local count = streamReadUInt8(streamId)\n"), "the host reads a client's checksum"),
 ("E8-mask-reads-on-the-host", NE, early("SoilScoutingMaskSyncEvent:readStream", "    self.schema     = streamReadUInt8(streamId)\n"), "the host reads a client's mask chunk"),
 # ── the counts ──────────────────────────────────────────────────────────────
 ("C1-batch-count-unbounded", NE,
  [("    if not sfCountWithinBound(count, SoilConstants.NETWORK.FULL_SYNC_BATCH_SIZE) then self.refused = \"FIELD_COUNT\" return end\n", "", 1)],
  "a batch of any size is read"),
 ("C2-batch-buffer-unbounded", NE,
  [("        local bCount = streamReadInt32(streamId)\n        if not sfCountWithinBound(bCount, SF_MAX_BUFFER_TYPES) then self.refused = \"BUFFER_COUNT\" return end\n",
    "        local bCount = streamReadInt32(streamId)\n", 1)],
  "a batch field's buffer count is trusted"),
 ("C3-batch-zones-unbounded", NE,
  [("        local zdCount = streamReadInt32(streamId)\n        if not sfCountWithinBound(zdCount, SF_ZONE_SYNC_MAX) then self.refused = \"ZONE_COUNT\" return end\n",
    "        local zdCount = streamReadInt32(streamId)\n", 1)],
  "a batch field's zone count is trusted"),
 ("C4-update-buffer-unbounded", NE,
  [("    local bCount = streamReadInt32(streamId)\n    if not sfCountWithinBound(bCount, SF_MAX_BUFFER_TYPES) then self.refused = \"BUFFER_COUNT\" return end\n",
    "    local bCount = streamReadInt32(streamId)\n", 1)],
  "a field update's buffer count is trusted"),
 ("C5-update-zones-unbounded", NE,
  [("    local zdCount = streamReadInt32(streamId)\n    if not sfCountWithinBound(zdCount, SF_ZONE_SYNC_MAX) then self.refused = \"ZONE_COUNT\" return end\n",
    "    local zdCount = streamReadInt32(streamId)\n", 1)],
  "a field update's zone count is trusted"),
 ("C6-full-sync-fields-unbounded", NE,
  [("    if not sfCountWithinBound(fieldCount, SF_MAX_SYNC_FIELDS) then self.refused = \"FIELD_COUNT\" return end\n", "", 1)],
  "the legacy inline field count is trusted"),
 ("C7-full-sync-buffer-unbounded", NE,
  [("        local bufferCount = streamReadInt32(streamId)\n        if not sfCountWithinBound(bufferCount, SF_MAX_BUFFER_TYPES) then self.refused = \"BUFFER_COUNT\" return end\n",
    "        local bufferCount = streamReadInt32(streamId)\n", 1)],
  "a full-sync field's buffer count is trusted"),
 ("C8-chunk-rows-unbounded", NE,
  [("    if not sfCountWithinBound(rowCount, SF_SYNC_ROWS_PER_EVENT) then self.refused = \"ROW_COUNT\" return end\n", "", 1)],
  "a chunk of any number of rows is read"),
 ("C9-row-shape-unbounded", NE,
  [("        if not sfCountWithinBound(rowLen, grid) or not sfCountWithinBound(numRuns, rowLen) then self.refused = \"ROW_SHAPE\" return end\n", "", 1)],
  "a row of any width with any number of runs is read"),
 ("C10-run-length-unbounded", NE,
  [("            if not sfCountWithinBound(len, rowLen - idx + 1) then self.refused = \"RUN_LENGTH\" return end\n", "", 1)],
  "a run past the row's end is iterated"),
 ("C11-mask-entries-unbounded", NE,
  [("    if not sfCountWithinBound(n, SoilScoutingMaskSyncEvent.MAX_ENTRIES) then self.refused = \"ENTRY_COUNT\" return end\n", "", 1)],
  "a mask chunk's entry count is trusted"),
 # ── the helper ──────────────────────────────────────────────────────────────
 ("H1-bound-is-exclusive", NE,
  [("    return type(count) == \"number\" and count >= 0 and count <= bound\n",
    "    return type(count) == \"number\" and count >= 0 and count < bound\n", 1)],
  "a count exactly at the writer's bound is refused"),
 ("H2-nil-count-passes", NE,
  [("    return type(count) == \"number\" and count >= 0 and count <= bound\n",
    "    return count == nil or (type(count) == \"number\" and count >= 0 and count <= bound)\n", 1)],
  "a short stream is looped on"),
 ("H3-reader-zone-bound-raised", NE,
  [("local SF_ZONE_SYNC_MAX       = 500", "local SF_ZONE_SYNC_MAX       = 5000", 1)],
  "the readers accept ten times what the writer sends"),
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
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
