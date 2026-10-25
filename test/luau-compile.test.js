const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { PATH_TO_COMPILER } = require("../src/config");
const { ROBLOX_SANDBOX_PATH } = require("../src/privateFiles");

// The bundle's Luau is only compiled when a worker loads it, and a Sandbox.luau that doesn't
// compile fails every run, so compile it here. Sandbox.luau is in the private luau-bot-headless
// checkout; its checks skip without it.
const ROBLOX = path.join(__dirname, "..", "roblox");
const skip = !fs.existsSync(PATH_TO_COMPILER);

function luauFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return luauFiles(full);
    return entry.name.endsWith(".luau") ? [full] : [];
  });
}

function compileError(file) {
  try {
    execFileSync(PATH_TO_COMPILER, ["--null", file], { stdio: "pipe" });
    return null;
  } catch (err) {
    return String(err.stderr || err.stdout || err.message).trim();
  }
}

test("every bundled Luau file compiles", { skip }, () => {
  const files = luauFiles(ROBLOX).concat(ROBLOX_SANDBOX_PATH ? [ROBLOX_SANDBOX_PATH] : []);
  const failures = files
    .map((file) => [path.basename(file), compileError(file)])
    .filter(([, error]) => error);
  assert.deepEqual(failures, []);
});

// Luau gives a function 200 registers, and Sandbox.luau's file scope holds ~190 locals at
// once. Fail here, with room to spare, rather than in the bundle.
test("Sandbox.luau has room for 8 more file-scope locals", { skip: skip || !ROBLOX_SANDBOX_PATH }, () => {
  const source = fs.readFileSync(ROBLOX_SANDBOX_PATH, "utf8");
  const at = source.indexOf("\nlocal ");
  assert.ok(at > 0, "no file-scope local found");
  const extra = Array.from({ length: 8 }, (_, i) => `local __headroom${i} = {}`).join("\n");
  const probe = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "luau-headroom-")), "Sandbox.luau");
  fs.writeFileSync(probe, `${source.slice(0, at)}\n${extra}${source.slice(at)}`);
  try {
    assert.equal(
      compileError(probe),
      null,
      "Sandbox.luau is near Luau's 200-register limit; move a section's locals into a do block",
    );
  } finally {
    fs.rmSync(path.dirname(probe), { recursive: true, force: true });
  }
});
