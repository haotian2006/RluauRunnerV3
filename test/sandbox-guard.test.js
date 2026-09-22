const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "roblox");

// Reading or calling these globals disables inlining, and a call marks the env
// unsafe (no imports/fastcalls). Table keys like `getfenv = "pure"` are fine.
const FENV_USE = /(?<![\w."'])(getfenv|setfenv)\b(?!\s*=\s*")/;

function codeLines(source) {
  return source
    .split(/\r?\n/)
    .map((line) => line.replace(/--.*$/, ""))
    .filter((line) => line.trim() !== "");
}

for (const file of ["Sandbox.luau", "LoadEnv.luau"]) {
  test(`${file} never references getfenv/setfenv`, () => {
    const source = fs.readFileSync(path.join(ROOT, file), "utf-8");
    const hits = codeLines(source).filter((line) => FENV_USE.test(line));
    assert.deepEqual(hits, []);
  });
}

test("LuauBot.luau never calls getfenv/setfenv", () => {
  const source = fs.readFileSync(path.join(ROOT, "LuauBot.luau"), "utf-8");
  assert.doesNotMatch(source, /\b(getfenv|setfenv)\s*\(/);
});

test("the sandbox globals table is in sync with the generator's lists", () => {
  const source = fs.readFileSync(path.join(ROOT, "Sandbox.luau"), "utf-8");
  assert.match(source, /--\[\[GLOBALS\]\][\s\S]*local GLOBALS = \{[\s\S]*--\[\[\/GLOBALS\]\]/);
  assert.doesNotMatch(source, /= "auto",/, "unclassified globals: run node scripts/sync-globals.js and classify them");
});
