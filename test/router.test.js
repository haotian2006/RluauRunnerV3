const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_ANALYZER, PATH_TO_AST } = require("../src/config");
const { classify } = require("../src/local/router");

const skip = !fs.existsSync(PATH_TO_ANALYZER) || !fs.existsSync(PATH_TO_AST);

test("Roblox-only io members and require(non-string) route to Roblox", { skip }, async () => {
  for (const source of [
    'local signal = require(io.import("https://github.com/Sleitnick/RbxUtil/blob/main/modules/signal/init.luau"))\nprint(signal)',
    'io.writeimage({}, "x")',
    'local f = io["import"]\nprint(f)',
    "local m = {}\nprint(require(m))",
  ]) {
    const result = await classify(source);
    assert.equal(result.eligible, false, source);
    assert.equal(result.reason, "roblox-only-members", source);
  }
});

test("the same words in strings, locals and plain io stay on Lune", { skip }, async () => {
  for (const source of [
    'print("io.import and writeimage and require(x)")',
    "local io = { import = function() return 1 end }\nprint(io.import())",
    'io.write("hi")',
    'print(require("./mod"))',
  ]) {
    const result = await classify(source);
    assert.equal(result.eligible, true, source);
  }
});
