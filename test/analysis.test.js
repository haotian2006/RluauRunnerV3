const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { PATH_TO_ROBLOX_ANALYZER, ROBLOX_TYPES_PATH } = require("../src/config");
const { analyzeLuau, findUnknownGlobals } = require("../src/tools/luau");
const skip = !fs.existsSync(PATH_TO_ROBLOX_ANALYZER) || !fs.existsSync(ROBLOX_TYPES_PATH);

test("Roblox analysis retains the annotated-source response and recognizes engine types", { skip }, async () => {
  const result = await analyzeLuau(`--!strict
local part = Instance.new("Part")
part.Size = Vector3.new(1, 2, 3)
part.Anchored = true
game:GetService("RunService").Heartbeat:Connect(function(dt: number)
    print(dt, CFrame.new(), Enum.Material.Plastic)
end)
return part
`, {});
  assert.deepEqual(Object.keys(result).sort(), ["code", "output"]);
  assert.equal(result.code, 0, result.output);
  assert.match(result.output, /local part\s*:\s*Part/);
  assert.match(result.output, /return part/);
  assert.doesNotMatch(result.output, /Unknown global|\[INFO\]|luau-[a-zA-Z0-9_-]+[\\/]/);
});

test("Roblox analysis reports actual property/type errors at the original source lines", { skip }, async () => {
  const source = fs.readFileSync(path.join(__dirname, "fixtures/roblox-analysis.luau"), "utf8");
  const result = await analyzeLuau(source, { annotate: true });
  assert.notEqual(result.code, 0);
  assert.match(result.output, /script\.luau\(8,13\): TypeError:.*Vector3.*string/);
  assert.match(result.output, /script\.luau\(9,1\): TypeError:.*FakeProperty.*Part/);
  assert.match(result.output, /local part\s*:\s*Part/);
  assert.doesNotMatch(result.output, /Unknown global|\[INFO\]|robloxTypes\.d\.luau/);
});

test("execution routing still uses the plain Luau global report", async () => {
  const result = await findUnknownGlobals("print(game, Instance, Vector3)");
  for (const name of ["game", "Instance", "Vector3"]) assert.ok(result.names.has(name));
});

test("snippet requires do not read host modules and inserted annotations retain diagnostic columns", { skip }, async () => {
  const file = path.join(os.tmpdir(), `analysis-host-fixture-${process.pid}.luau`);
  const moduleName = `../${path.basename(file, ".luau")}`;
  fs.writeFileSync(file, 'return ("PRIVATE_ANALYSIS_SENTINEL" :: "PRIVATE_ANALYSIS_SENTINEL")');
  try {
    const line = `local label = "🙂"; local value: number = require(require("${moduleName}")); local part = Instance.new("Part"); part.Size = "wrong"; print(label, value)`;
    const result = await analyzeLuau(`--!strict\n${line}`);
    assert.doesNotMatch(result.output, /PRIVATE_ANALYSIS_SENTINEL/);
    assert.doesNotMatch(result.output, /SyntaxError/);
    const column = Buffer.byteLength(line.slice(0, line.indexOf('"wrong"')), "utf8") + 1;
    assert.match(result.output, new RegExp(`script\\.luau\\(2,${column}\\): TypeError:.*Vector3.*string`));
  } finally { fs.unlinkSync(file); }
});

test("invalid snippets containing require return ordinary syntax diagnostics", { skip }, async () => {
  const result = await analyzeLuau("local = require('../missing')");
  assert.equal(result.code, 1);
  assert.match(result.output, /script\.luau\(1,7\): SyntaxError: Expected identifier/);
  assert.doesNotMatch(result.output, /\{"root"|SyntaxError: Unexpected token/);
});
