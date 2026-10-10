const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { Readable } = require("stream");
const { execFileSync } = require("child_process");

const { PATH_TO_LUNE } = require("../src/config");
const { parseGithubUrl, readArchive, runBuild, ImportError } = require("../src/github/import");

const hasLune = fs.existsSync(PATH_TO_LUNE);

test("parses repository, folder, file, raw and release URLs", () => {
  assert.deepEqual(parseGithubUrl("https://github.com/Parihsz/Chrono"), {
    mode: "repo",
    owner: "Parihsz",
    repo: "Chrono",
    candidates: [{ ref: "HEAD", path: "" }],
  });
  const tree = parseGithubUrl("https://github.com/o/r/tree/feature/x/src/Shared");
  assert.equal(tree.mode, "path");
  assert.deepEqual(tree.candidates[0], { ref: "feature", path: "x/src/Shared" });
  assert.deepEqual(tree.candidates[1], { ref: "feature/x", path: "src/Shared" });
  assert.equal(parseGithubUrl("https://github.com/o/r.git").repo, "r");
  assert.equal(parseGithubUrl("https://github.com/o/r/blob/main/src/A.luau").candidates[0].path, "src/A.luau");
  assert.equal(parseGithubUrl("https://raw.githubusercontent.com/o/r/main/src/A.luau").mode, "path");
  const rel = parseGithubUrl("https://github.com/o/r/releases/download/v1/build.rbxm");
  assert.equal(rel.mode, "model");
  assert.equal(rel.name, "build");
  assert.equal(rel.url, "https://github.com/o/r/releases/download/v1/build.rbxm");
});

test("rejects other hosts and malformed GitHub URLs", () => {
  for (const bad of [
    "https://gitlab.com/o/r",
    "file:///etc/passwd",
    "not a url",
    "https://github.com/o",
    "https://github.com/o/r/issues/1",
    "https://github.com/o/r/releases/download/v1/notes.txt",
  ]) {
    assert.throws(() => parseGithubUrl(bad), ImportError, bad);
  }
  // the URL parser resolves dot segments, so nothing reaches the build with ".." in it
  for (const c of parseGithubUrl("https://github.com/o/r/tree/main/%2e%2e/x").candidates) {
    assert.ok(!`${c.ref}/${c.path}`.split("/").includes(".."));
  }
});

function tarEntry(name, data, type = "0", linkname = "") {
  const h = Buffer.alloc(512);
  h.write(name, 0, 100);
  h.write("0000644\0", 100);
  h.write("0000000\0", 108);
  h.write("0000000\0", 116);
  h.write(data.length.toString(8).padStart(11, "0") + "\0", 124);
  h.write("00000000000\0", 136);
  h.write("        ", 148);
  h.write(type, 156);
  h.write(linkname, 157, 100);
  h.write("ustar\0", 257);
  h.write("00", 263);
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148);
  const pad = Buffer.alloc((512 - (data.length % 512)) % 512);
  return Buffer.concat([h, data, pad]);
}

function tarGz(entries) {
  const parts = entries.map((e) => tarEntry(e.name, Buffer.from(e.data ?? ""), e.type, e.link));
  return zlib.gzipSync(Buffer.concat([...parts, Buffer.alloc(1024)]));
}

test("archive reader keeps only safe, syncable regular files", async () => {
  const gz = tarGz([
    { name: "repo-abc/src/init.luau", data: "return {}" },
    { name: "repo-abc/src/Util.luau", data: "return 1" },
    { name: "repo-abc/assets/big.png", data: "png" },
    { name: "repo-abc/src/Link.luau", type: "2", link: "/etc/passwd" },
    { name: "repo-abc/src/../../escape.luau", data: "x" },
    { name: "repo-abc/default.project.json", data: "{}" },
  ]);
  const files = await readArchive(Readable.from([gz]));
  assert.deepEqual([...files.keys()].sort(), ["default.project.json", "src/Util.luau", "src/init.luau"]);
  assert.equal(files.get("src/Util.luau").toString(), "return 1");
});

function dumpModel(bytes) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "import-test-"));
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
	local extra = ""
	pcall(function() extra = " src=" .. i.Source end)
	pcall(function() extra = " value=" .. i.Value end)
	pcall(function() if i:IsA("BasePart") then extra = " size=" .. tostring(i.Size) end end)
	table.insert(out, p .. " " .. i.ClassName .. extra)
	for _, c in i:GetChildren() do walk(c, p .. "/" .. c.Name) end
end
walk(root, root.Name)
table.sort(out)
print(table.concat(out, "\\n"))`,
  );
  try {
    return execFileSync(PATH_TO_LUNE, ["run", script, model], { encoding: "utf8" }).trim().split("\n");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const files = (obj) => new Map(Object.entries(obj).map(([k, v]) => [k, Buffer.from(v)]));

test("builds src with Rojo's file rules", { skip: !hasLune }, async () => {
  const bytes = await runBuild(
    { mode: "repo", name: "Lib" },
    files({
      "src/init.luau": "return 'root'",
      "src/Server/Main.server.luau": "print(1)",
      "src/Client/Main.client.lua": "print(2)",
      "src/Shared/init.meta.json": JSON.stringify({ className: "Configuration" }),
      "src/Shared/Data.json": JSON.stringify({ a: [1, 2], b: "x" }),
      "src/Shared/Note.txt": "hello",
      "src/Shared/Box.model.json": JSON.stringify({ ClassName: "Part", Properties: { Size: [1, 2, 3] } }),
      "README.md": "ignored",
    }),
  );
  const tree = dumpModel(bytes);
  assert.ok(tree.includes("Lib ModuleScript src=return 'root'"), tree.join("\n"));
  assert.ok(tree.includes("Lib/Server/Main Script src=print(1)"));
  assert.ok(tree.includes("Lib/Client/Main LocalScript src=print(2)"));
  assert.ok(tree.includes("Lib/Shared Configuration"));
  assert.ok(tree.includes("Lib/Shared/Note StringValue value=hello"));
  assert.ok(tree.includes("Lib/Shared/Box Part size=1, 2, 3"));
  assert.ok(tree.some((l) => l.startsWith("Lib/Shared/Data ModuleScript src=return {")));
});

test("follows default.project.json and refuses $paths outside the repo", { skip: !hasLune }, async () => {
  const project = JSON.stringify({ name: "Proj", tree: { $className: "Folder", Shared: { $path: "lib" } } });
  const bytes = await runBuild({ mode: "repo", name: "repo" }, files({ "default.project.json": project, "lib/A.luau": "return 1" }));
  const tree = dumpModel(bytes);
  assert.ok(tree.includes("Proj Folder"));
  assert.ok(tree.includes("Proj/Shared/A ModuleScript src=return 1"));

  const escape = JSON.stringify({ name: "Bad", tree: { $path: "../../etc" } });
  await assert.rejects(runBuild({ mode: "repo", name: "repo" }, files({ "default.project.json": escape })), /leaves the repository/);
});

test("errors when there's no project file or src folder", { skip: !hasLune }, async () => {
  await assert.rejects(runBuild({ mode: "repo", name: "repo" }, files({ "lib/A.luau": "return 1" })), /no default.project.json or src/);
});
