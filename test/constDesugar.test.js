const test = require("node:test");
const assert = require("node:assert/strict");

const { desugarConstForLune } = require("../src/local/constDesugar");

test("const declarations become local, everything else is untouched", async () => {
  const src = [
    "local y = 5",
    "const x = y",
    "local msg = \"this has the word const inside a string\"",
    "-- const in a comment should stay untouched",
    "const z = x + 1",
    "print(x, z, msg)",
  ].join("\n");

  const out = await desugarConstForLune(src);

  assert.equal(
    out,
    [
      "local y = 5",
      "local x = y",
      "local msg = \"this has the word const inside a string\"",
      "-- const in a comment should stay untouched",
      "local z = x + 1",
      "print(x, z, msg)",
    ].join("\n"),
  );
});

test("source with no const declarations is returned unchanged", async () => {
  const src = "local x = 1\nprint(x)";
  assert.equal(await desugarConstForLune(src), src);
});
