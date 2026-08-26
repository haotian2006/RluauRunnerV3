const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_LUNE } = require("../src/config");
const { runLocal } = require("../src/local/run");

test("Lune rechecks admission after receiving a queue slot", async () => {
  const result = await runLocal("print(1)", {
    beforeStart() {
      return "Queued execution is now blocked";
    },
  });

  assert.equal(result.admissionRejected, true);
  assert.equal(result.error, "Queued execution is now blocked");
});

test(
  "Lune identifies a non-yielding timeout as blocked",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const startedAt = Date.now();
    const result = await runLocal("while true do end", {
      heartbeatTimeoutMs: 700,
      timeoutMs: 1500,
    });

    assert.equal(result.timedOut, true);
    assert.equal(result.timeoutKind, "blocked");
    assert.ok(Date.now() - startedAt < 1300);
    assert.equal(
      result.error,
      "Script timeout: exhausted allowed execution time",
    );
  },
);

test(
  "Lune identifies a responsive yielding timeout",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    let starts = 0;
    let heartbeats = 0;
    const result = await runLocal("while true do task.wait() end", {
      heartbeatTimeoutMs: 700,
      timeoutMs: 1500,
      onStarted() {
        starts += 1;
      },
      onHeartbeat() {
        heartbeats += 1;
      },
    });

    assert.equal(result.timedOut, true);
    assert.equal(result.timeoutKind, "yielding");
    assert.match(result.error, /lifespan while yielding$/);
    assert.equal(starts, 1);
    assert.ok(heartbeats > 0);
  },
);
