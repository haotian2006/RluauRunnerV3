const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_LUNE } = require("../src/config");
const { runLocal } = require("../src/local/run");

test(
  "a user cancellation terminates Lune without becoming a timeout",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const controller = new AbortController();
    const startedAt = Date.now();
    const run = runLocal("while true do end", {
      signal: controller.signal,
      timeoutMs: 5_000,
    });

    setTimeout(() => controller.abort(), 100);
    const result = await run;

    assert.equal(result.cancelled, true);
    assert.equal(result.timedOut, false);
    assert.ok(Date.now() - startedAt < 4_000);
  },
);
