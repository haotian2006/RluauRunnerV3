const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// On a headless Studio worker LuauBot and its runs are at identity 2, where the engine refuses these
// (luau-bot-headless docs/box-workers.md). Code that needs one goes through the run's broker
// (hooks.deserializeModel, hooks.serializeModel, hooks.readSource) instead.
const RESTRICTED = [
  /GetService\(\s*["'](SerializationService|ScriptEditorService|StudioService|PluginGuiService|ChangeHistoryService|CoreGui|Selection)["']\s*\)/,
  /\bsettings\(\s*\)/,
  /\bPluginManager\b/,
  /\.Source\b/,
];

// The Open Cloud fallbacks after a broker check.
const ALLOWED = {
  "LuauBot.luau": [
    "m.Source = src",
    "instance.Source = source",
    "return instance.Source",
    'return game:GetService("SerializationService"):SerializeInstancesAsync(roots)',
    'local roots = game:GetService("SerializationService"):DeserializeInstancesAsync(contents)',
  ],
};

const ROBLOX = path.join(__dirname, "..", "roblox");

function luauFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return luauFiles(full);
    return entry.name.endsWith(".luau") ? [full] : [];
  });
}

test("bundled Luau only reaches Studio-restricted APIs through the broker", () => {
  const files = luauFiles(ROBLOX);
  const found = [];
  for (const file of files) {
    const allowed = ALLOWED[path.basename(file)] || [];
    fs.readFileSync(file, "utf8")
      .split(/\r?\n/)
      .forEach((line, index) => {
        const code = line.replace(/--.*$/, "").trim();
        if (!code || !RESTRICTED.some((pattern) => pattern.test(code))) return;
        if (allowed.includes(code)) return;
        found.push(`${path.basename(file)}:${index + 1}: ${code}`);
      });
  }
  assert.deepEqual(found, []);
});
