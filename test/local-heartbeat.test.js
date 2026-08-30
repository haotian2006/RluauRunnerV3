const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const {
  LOCAL_MAX_CONCURRENT,
  PATH_TO_LUNE,
} = require("../src/config");
const { closeSession, hasSession, openSession } = require("../src/core/sessions");
const { tryRunLocally } = require("../src/local/dispatch");
const { queueDepth, runLocal } = require("../src/local/run");

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
  "busy Lune slots decline automatic work but still queue forced work",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 15_000 },
  async () => {
    const controllers = [];
    const runs = [];
    const started = [];

    for (let index = 0; index < LOCAL_MAX_CONCURRENT; index += 1) {
      const controller = new AbortController();
      controllers.push(controller);
      started.push(
        new Promise((resolve) => {
          runs.push(
            runLocal("while true do task.wait() end", {
              signal: controller.signal,
              timeoutMs: 10_000,
              onStarted: resolve,
            }),
          );
        }),
      );
    }

    try {
      await Promise.all(started);

      const busy = await runLocal("print(1)", { queueIfBusy: false });
      assert.equal(busy.luneBusy, true);
      assert.equal(queueDepth(), 0);

      const fallbackToken = `busy-fallback:${Date.now()}`;
      openSession(fallbackToken, { async deliver() {}, close() {} });
      const ranLocally = await tryRunLocally("print(1)", fallbackToken, {
        actorKey: `discord:busy-${Date.now()}:lune`,
        selection: {
          runtime: "lune",
          classification: { forced: false },
        },
      });
      assert.equal(ranLocally, false);
      assert.equal(hasSession(fallbackToken), true);
      closeSession(fallbackToken);

      const queuedController = new AbortController();
      const queued = runLocal("print(1)", {
        queueIfBusy: true,
        signal: queuedController.signal,
      });
      await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(queueDepth(), 1);
      queuedController.abort();
      assert.equal((await queued).cancelled, true);
    } finally {
      controllers.forEach((controller) => controller.abort());
      await Promise.all(runs);
    }
  },
);

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
