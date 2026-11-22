// =============================================================================
//  🧪 Patch-Fixture-Test für install/papermark-inner.sh
//
//  Extrahiert den Patch-Generator (apply-patches.mjs) aus dem Inner-Skript,
//  liest die Patch-Definitionen (find/replace) und baut daraus Fixture-Dateien.
//  Damit wird geprüft, dass
//    • jeder Anker im echten Patch-Satz genau einmal vorkommt (kein Drift),
//    • die Patches sauber anwendbar sind,
//    • ein fehlender Anker zum lauten Abbruch führt (kein stiller Bypass).
//
//  Das ersetzt keinen Live-Test gegen den echten Upstream-Code, fängt aber
//  kaputte Anker und Syntaxfehler im Patch-Skript sofort ab.
//  Usage: node harness/test-patches.mjs <pfad-zu-papermark-inner.sh>
// =============================================================================
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const inner = process.argv[2];
if (!inner || !fs.existsSync(inner)) {
  console.error("✘ Inner-Skript nicht gefunden:", inner);
  process.exit(2);
}

const text = fs.readFileSync(inner, "utf8");
const m = text.match(
  /cat > \/tmp\/apply-patches\.mjs <<'PATCH_EOF'\n([\s\S]*?)\nPATCH_EOF/,
);
if (!m) {
  console.error("✘ apply-patches.mjs-Block im Inner-Skript nicht gefunden");
  process.exit(2);
}
const patchSrc = m[1];

// Nur den Definitionsteil auswerten (bis "let applied = 0;"), damit der
// Generator beim Auslesen nichts anwendet und sich nicht beendet. Die
// import-Zeilen entfallen (fs/path/process werden injiziert).
const head = patchSrc
  .split("let applied = 0;")[0]
  .split("\n")
  .filter((line) => !line.startsWith("import "))
  .join("\n");
if (!head.includes("const patches")) {
  console.error("✘ Patch-Definitionen (const patches) nicht gefunden");
  process.exit(2);
}
const factory = new Function("fs", "path", "process", `${head}\nreturn patches;`);
const patches = factory(fs, path, { argv: [process.argv[0], "apply-patches.mjs", "/nonexistent"] });

if (!Array.isArray(patches) || patches.length === 0) {
  console.error("✘ keine Patches in apply-patches.mjs gefunden");
  process.exit(2);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "papermark-patchtest-"));
const srcFile = path.join(tmp, "apply-patches.mjs");
fs.writeFileSync(srcFile, patchSrc);

let failed = 0;
const ok = (msg) => console.log(`  ✔ ${msg}`);
const fail = (msg) => {
  failed++;
  console.log(`  ✘ ${msg}`);
};

// ── Fixture bauen: pro Datei alle Anker in Reihenfolge aneinanderhängen ──────
const byFile = new Map();
for (const p of patches) {
  if (!byFile.has(p.file)) byFile.set(p.file, []);
  byFile.get(p.file).push(p);
}

function buildFixture(rootDir, { breakFirstAnchor = false } = {}) {
  for (const [file, list] of byFile) {
    const target = path.join(rootDir, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    let parts = list.map((p) => p.find);
    if (breakFirstAnchor && parts.length > 0) {
      parts[0] = parts[0].split("\n").slice(1).join("\n");
    }
    fs.writeFileSync(target, parts.join("\n\n// fixture\n\n"));
  }
}

const fixture = path.join(tmp, "fixture");
buildFixture(fixture);

// ── 1) Positiv: alle Patches müssen auf der Fixture anwendbar sein ──────────
try {
  const out = execFileSync(process.execPath, [srcFile, fixture], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const n = Number((out.match(/(\d+) Selfhosting-Patches angewendet/) || [])[1]);
  if (n === patches.length) ok(`${n}/${patches.length} Patches angewendet`);
  else fail(`${n}/${patches.length} Patches angewendet (erwartet ${patches.length})`);
} catch (err) {
  fail(`Patch-Lauf fehlgeschlagen: ${err.stderr?.toString().trim() || err.message}`);
}

// ── 2) Negativ: fehlender Anker muss mit Exit != 0 abbrechen ───────────────
const broken = path.join(tmp, "broken");
buildFixture(broken, { breakFirstAnchor: true });
try {
  execFileSync(process.execPath, [srcFile, broken], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  fail("Fehlender Anker hat NICHT abgebrochen");
} catch (err) {
  const stderr = err.stderr?.toString() || "";
  if (/Anker nicht gefunden/.test(stderr)) ok("Fehlender Anker → lauter Abbruch mit Meldung");
  else fail(`Abbruch ohne verständliche Meldung: ${stderr.trim().slice(0, 140)}`);
}

// ── 3) Ergebnis prüfen: jede Ersetzung muss in der Fixture-Resultatdatei stecken ──
for (const [file, list] of byFile) {
  const content = fs.readFileSync(path.join(fixture, file), "utf8");
  const missing = list.filter((p) => !content.includes(p.replace)).length;
  if (missing === 0) ok(`${file}: alle ${list.length} Ersetzungen enthalten`);
  else fail(`${file}: ${missing} Ersetzungen fehlen im Ergebnis`);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed === 0 ? "  → Patch-Fixtures grün" : `  → ${failed} Fehler`);
process.exit(failed === 0 ? 0 : 1);