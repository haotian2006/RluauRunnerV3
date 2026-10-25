const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const { ROBLOX_SANDBOX_PATH } = require("../src/privateFiles");

const ROOT = path.join(__dirname, "..", "roblox");
// Sandbox.luau is in the private luau-bot-headless checkout; skipped without it.
const SOURCES = { "Sandbox.luau": ROBLOX_SANDBOX_PATH, "LoadEnv.luau": path.join(ROOT, "LoadEnv.luau") };
const noSandbox = !ROBLOX_SANDBOX_PATH;

// Reading or calling these globals disables inlining, and a call marks the env
// unsafe (no imports/fastcalls). Table keys like `getfenv = "pure"` are fine.
const FENV_USE = /(?<![\w."'])(getfenv|setfenv)\b(?!\s*=\s*")/;
// The one sanctioned reference: Sandbox captures the real reader to back its own getfenv override.
const ALLOWED = /^\s*local realGetfenv = getfenv\s*$/;

function codeLines(source) {
  return source
    .split(/\r?\n/)
    .map((line) => line.replace(/--.*$/, ""))
    .filter((line) => line.trim() !== "");
}

for (const [file, location] of Object.entries(SOURCES)) {
  test(`${file} never references getfenv/setfenv`, { skip: !location }, () => {
    const source = fs.readFileSync(location, "utf-8");
    const hits = codeLines(source).filter((line) => FENV_USE.test(line) && !ALLOWED.test(line));
    assert.deepEqual(hits, []);
  });
}

test("LuauBot.luau never calls getfenv/setfenv", () => {
  const source = fs.readFileSync(path.join(ROOT, "LuauBot.luau"), "utf-8");
  assert.doesNotMatch(source, /\b(getfenv|setfenv)\s*\(/);
});

test("the sandbox globals table is in sync with the generator's lists", { skip: noSandbox }, () => {
  const source = fs.readFileSync(ROBLOX_SANDBOX_PATH, "utf-8");
  assert.match(source, /--\[\[GLOBALS\]\][\s\S]*local GLOBALS = \{[\s\S]*--\[\[\/GLOBALS\]\]/);
  assert.doesNotMatch(source, /= "auto",/, "unclassified globals: run node scripts/sync-globals.js and classify them");
});
