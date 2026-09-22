const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "roblox");

// Any mention of these globals disables inlining, and a call marks the env unsafe (no imports/fastcalls).
for (const file of ["Sandbox.luau", "LoadEnv.luau"]) {
  test(`${file} never mentions getfenv/setfenv`, () => {
    const source = fs.readFileSync(path.join(ROOT, file), "utf-8");
    assert.doesNotMatch(source, /\b(getfenv|setfenv)\b/);
  });
}

test("LuauBot.luau never calls getfenv/setfenv", () => {
  const source = fs.readFileSync(path.join(ROOT, "LuauBot.luau"), "utf-8");
  assert.doesNotMatch(source, /\b(getfenv|setfenv)\s*\(/);
});
