const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { execFileSync } = require("child_process");

const { PATH_TO_LUNE } = require("../src/config");
const { runBuild } = require("../src/github/import");
const { parseWallyTarget, parseRequirement, pickVersion, readZip, buildWally } = require("../src/github/wally");
const { ImportError } = require("../src/github/common");

const versions = (...list) => list.map((version) => ({ package: { version } }));
const pick = (req, ...list) => pickVersion(versions(...list), req)?.ver.text ?? null;

test("parses wally: specs and wally.run links", () => {
  assert.deepEqual(parseWallyTarget("wally:sleitnick/knit@1.7"), { mode: "wally", scope: "sleitnick", name: "knit", req: "1.7" });
  assert.equal(parseWallyTarget("wally:Sleitnick/Signal").req, "*");
  assert.deepEqual(parseWallyTarget("https://wally.run/package/sleitnick/signal?version=2.0.1"), {
    mode: "wally",
    scope: "sleitnick",
    name: "signal",
    req: "=2.0.1",
  });
  assert.equal(parseWallyTarget("https://github.com/a/b"), null);
  for (const bad of ["wally:nope", "wally:a/b/c", "wally:a/b@not a version", "https://wally.run/whatever"]) {
    assert.throws(() => parseWallyTarget(bad), ImportError, bad);
  }
});

test("matches Cargo-style requirements like Wally", () => {
  const all = ["0.1.0", "0.1.5", "0.2.0", "1.0.0", "1.4.2", "1.7.0", "1.7.3", "2.0.0", "2.1.0-beta"];
  assert.equal(pick("1.7", ...all), "1.7.3");
  assert.equal(pick("^1.4", ...all), "1.7.3");
  assert.equal(pick("~1.4", ...all), "1.4.2");
  assert.equal(pick("=1.7.0", ...all), "1.7.0");
  assert.equal(pick(">=1.0.0, <2.0.0", ...all), "1.7.3");
  assert.equal(pick("^0.1", ...all), "0.1.5");
  assert.equal(pick("*", ...all), "2.0.0");
  assert.equal(pick("<=1.4", ...all), "1.4.2");
  assert.equal(pick("3", ...all), null);
  assert.throws(() => parseRequirement("abc"), ImportError);
});

function zip(entries) {
  const locals = [];
  const central = [];
  let offset = 0;
  for (const { name, data, deflate } of entries) {
    const raw = Buffer.from(data);
    const body = deflate ? zlib.deflateRawSync(raw) : raw;
    const n = Buffer.from(name);
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0);
    lh.writeUInt16LE(deflate ? 8 : 0, 8);
    lh.writeUInt32LE(body.length, 18);
    lh.writeUInt32LE(raw.length, 22);
    lh.writeUInt16LE(n.length, 26);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0);
    ch.writeUInt16LE(deflate ? 8 : 0, 10);
    ch.writeUInt32LE(body.length, 20);
    ch.writeUInt32LE(raw.length, 24);
    ch.writeUInt16LE(n.length, 28);
    ch.writeUInt32LE(offset, 42);
    locals.push(lh, n, body);
    central.push(ch, n);
    offset += 30 + n.length + body.length;
  }
  const cd = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

test("zip reader keeps safe, syncable files from stored and deflated entries", () => {
  const files = readZip(
    zip([
      { name: "init.lua", data: "return 1", deflate: true },
      { name: "src/Util.luau", data: "return 2" },
      { name: "README.md", data: "skip" },
      { name: "../escape.lua", data: "x" },
      { name: "dir/", data: "" },
    ]),
  );
  assert.deepEqual([...files.keys()].sort(), ["init.lua", "src/Util.luau"]);
  assert.equal(files.get("init.lua").toString(), "return 1");
});

function dumpModel(bytes) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wally-test-"));
  const model = path.join(dir, "m.rbxm");
  const script = path.join(dir, "dump.luau");
  fs.writeFileSync(model, bytes);
  fs.writeFileSync(
    script,
    `local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local root = roblox.deserializeModel(fs.readFile(process.args[1]))[1]
local out = {}
local function walk(i, p)
	local src = ""
	pcall(function() src = " " .. i.Source end)
	table.insert(out, p .. " " .. i.ClassName .. src)
	for _, c in i:GetChildren() do walk(c, p .. "/" .. c.Name) end
end
walk(root, root.Name)
table.sort(out)
print(table.concat(out, "\\n"))`,
  );
  try {
    return execFileSync(PATH_TO_LUNE, ["run", script, model], { encoding: "utf8" }).split("\n").filter(Boolean);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test("builds a package and its dependencies in Wally's layout", { skip: !fs.existsSync(PATH_TO_LUNE) }, async (t) => {
  const registry = {
    "acme/app": [{ package: { version: "1.2.0" }, dependencies: { Lib: "acme/lib@^2" } }],
    "acme/lib": [{ package: { version: "2.3.1" } }, { package: { version: "3.0.0" } }],
  };
  const archives = {
    "acme/app/1.2.0": zip([{ name: "init.lua", data: "return require(script.Parent.Lib)" }]),
    "acme/lib/2.3.1": zip([{ name: "init.lua", data: "return 'lib'", deflate: true }]),
  };
  const original = global.fetch;
  global.fetch = async (url) => {
    const meta = /package-metadata\/(.+)$/.exec(url);
    if (meta) return new Response(JSON.stringify({ versions: registry[meta[1]] }));
    const body = /package-contents\/(.+)$/.exec(url);
    if (body) return new Response(archives[body[1]]);
    throw new Error(`unexpected ${url}`);
  };
  t.after(() => (global.fetch = original));

  const tree = dumpModel(await buildWally(parseWallyTarget("wally:acme/app"), runBuild));
  assert.deepEqual(tree, [
    'app ModuleScript return require(script._Index["acme_app@1.2.0"]["app"])',
    "app/_Index Folder",
    "app/_Index/acme_app@1.2.0 Folder",
    'app/_Index/acme_app@1.2.0/Lib ModuleScript return require(script.Parent.Parent["acme_lib@2.3.1"]["lib"])',
    "app/_Index/acme_app@1.2.0/app ModuleScript return require(script.Parent.Lib)",
    "app/_Index/acme_lib@2.3.1 Folder",
    "app/_Index/acme_lib@2.3.1/lib ModuleScript return 'lib'",
  ]);
});
