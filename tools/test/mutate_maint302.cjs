const fs = require("fs"), cp = require("child_process"), crypto = require("crypto"), path = require("path");
// Mutant battery for MAINTENANCE row 302 (the field hook returns the engine's task).
// Usage: node tools/test/mutate_maint302.cjs   (run from anywhere; restores the file)
const wt = process.argv[2] || path.resolve(__dirname, "../..");
const file = path.join(wt, "src/ui/RfPdaSoilMerge.lua");
const orig = fs.readFileSync(file, "utf8");
const h = (s) => crypto.createHash("sha1").update(s).digest("hex").slice(0, 12);
const H0 = h(orig);
// The checkout is CRLF (core.autocrlf); anchors are written with \n and converted.
const nl = orig.includes("\r\n") ? (x) => x.replace(/\r?\n/g, "\r\n") : (x) => x;
const call = "return markWorked(field, superFunc(fieldManager, field, ...))";
const mutants = [
  ["M1 drop the return", call, "markWorked(field, superFunc(fieldManager, field, ...))"],
  ["M2 markWorked returns nothing", "    return ...\nend\n\n--- Read-only subscriptions", "    return\nend\n\n--- Read-only subscriptions"],
  ["M3 never marks dirty", "            fn(id)\n", "\n"],
  ["M4 marks before the engine runs", call, "markWorked(field); return superFunc(fieldManager, field, ...)"],
  ["M5 back to appendedFunction",
    "Utils.overwrittenFunction(FieldManager[name], function(fieldManager, superFunc, field, ...)\n                    " + call + "\n                end)",
    "Utils.appendedFunction(FieldManager[name], function(_, field) markWorked(field) end)"],
  ["M6 engine called without the field", "superFunc(fieldManager, field, ...)", "superFunc(fieldManager, nil, ...)"],
];
let killed = 0, ran = 0;
try {
  for (const [name, rawFrom, rawTo] of mutants) {
    const from = nl(rawFrom), to = nl(rawTo);
    const n = orig.split(from).length - 1;
    if (n !== 1) { console.log(`${name}: anchor found ${n} times, NOT RUN`); continue; }
    fs.writeFileSync(file, orig.replace(from, to));
    if (h(fs.readFileSync(file, "utf8")) === H0) { console.log(`${name}: mutation did not land, NOT RUN`); continue; }
    ran++;
    let out = "";
    try {
      out = cp.execSync("node run-tests.mjs --loads src/ui/RfPdaSoilMerge.lua",
        { cwd: path.join(wt, "tools/test"), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) { out = (e.stdout || "") + (e.stderr || ""); }
    const line = (out.match(/^.*MAINT-302.*$/m) || ["(no MAINT-302 line)"])[0].trim();
    const survived = /\(\d+ passed, 0 failed\)$/.test(line) && !/error/i.test(line);
    if (!survived) killed++;
    const fails = (out.match(/FAIL 302 [A-D]\d+/g) || []).slice(0, 4).join(", ");
    console.log(`${name}: ${survived ? "SURVIVED" : "KILLED"} :: ${line}${fails ? " :: " + fails : ""}`);
  }
} finally {
  fs.writeFileSync(file, orig);
  console.log(`restored ${h(fs.readFileSync(file, "utf8")) === H0 ? "OK" : "MISMATCH"} (${H0}); killed ${killed} of ${ran} run, ${mutants.length} defined`);
}
