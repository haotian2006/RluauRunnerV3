const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { tokenTag } = require("../src/log");

// A whole Discord interaction or web run token in a log line reaches the journal and the status
// page; log lines use tokenTag (its last 8 characters) instead.
const WHOLE_TOKEN = /\$\{\s*(?:[A-Za-z_]+\.)?token\s*\}/;

function jsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return jsFiles(full);
    return entry.name.endsWith(".js") ? [full] : [];
  });
}

test("tokenTag keeps only the last 8 characters", () => {
  assert.equal(tokenTag("aW50ZXJhY3Rpb246MTIzNDU2Nzg5OmFiY2RlZmdo"), "OmFiY2RlZmdo".slice(-8));
  assert.equal(tokenTag(12345), "12345");
});

test("log calls never interpolate a whole token", () => {
  const found = [];
  for (const file of jsFiles(path.join(__dirname, "..", "src"))) {
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    lines.forEach((line, index) => {
      if (!/\b(logBot|console\.(log|warn|error))\(/.test(line)) return;
      // A call's message can sit on the next few lines.
      const call = lines.slice(index, index + 4).join("\n");
      if (WHOLE_TOKEN.test(call)) found.push(`${path.basename(file)}:${index + 1}`);
    });
  }
  assert.deepEqual(found, []);
});
