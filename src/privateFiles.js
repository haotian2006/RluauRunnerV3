const fs = require("fs");
const path = require("path");

// The sandboxes live in the private luau-bot-headless repository (sandbox/), not in this public
// one. It is found through LUAU_BOT_PRIVATE_DIR, or checked out beside this repository.
// scripts/bundle.luau looks it up the same way.
const ROOT_DIR = path.join(__dirname, "..");

function findPrivateDir() {
  const candidates = [
    process.env.LUAU_BOT_PRIVATE_DIR,
    path.join(ROOT_DIR, "..", "luau-bot-headless"),
    path.join(ROOT_DIR, "..", "studio-mods"),
  ].filter(Boolean);
  return candidates.find((dir) => fs.existsSync(path.join(dir, "sandbox"))) || null;
}

const PRIVATE_DIR = findPrivateDir();
const privatePath = (relative) => (PRIVATE_DIR ? path.join(PRIVATE_DIR, relative) : null);

module.exports = {
  PRIVATE_DIR,
  // Roblox runs' sandbox, bundled under LoadEnv.
  ROBLOX_SANDBOX_PATH: privatePath("sandbox/Sandbox.luau"),
  // The local Lune runner's sandbox.
  LUNE_SANDBOX_PATH: privatePath("sandbox/lune-sandbox.luau"),
};
