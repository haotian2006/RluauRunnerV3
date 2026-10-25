// Copies the Lune adapters from luau-bot-headless (studio-mods) into roblox/ and
// rebuilds luauBot.b64 with scripts/bundle. Local only: no publish, workers or bot.
//   node scripts/install-lune-libraries.js [path to luau-bot-headless]
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const root = path.resolve(__dirname, "..");
const studio = path.resolve(
  process.argv[2] ||
    ["../luau-bot-headless", "../studio-mods"].map((dir) => path.join(root, dir)).find((dir) => fs.existsSync(dir)) ||
    path.join(root, "../luau-bot-headless")
);
for (const [from, to] of [["lune-imports.luau", "LuneImports.luau"], ["virtual-fs.luau", "VirtualFs.luau"]]) {
  fs.copyFileSync(path.join(studio, "mods/headless/scripts", from), path.join(root, "roblox", to));
}
const bundle = path.join(root, "luauBot.b64");
if (fs.existsSync(bundle)) {
  const build = path.join(studio, "build");
  fs.mkdirSync(build, { recursive: true });
  fs.copyFileSync(bundle, path.join(build, `bot-before-lune-${Date.now()}.b64`));
}
const lune = path.join(root, "bin", process.platform === "win32" ? "lune.exe" : "lune");
const result = spawnSync(lune, ["run", "scripts/bundle", "build"], { cwd: root, encoding: "utf8", timeout: 60000, windowsHide: true });
if (result.stdout) process.stdout.write(result.stdout);
if (result.status !== 0) throw new Error(result.stderr || result.error?.message || "Bundle build failed");
console.log("Local bundle rebuilt; SHA256:", crypto.createHash("sha256").update(fs.readFileSync(bundle, "utf8")).digest("hex"));
