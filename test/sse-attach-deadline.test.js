const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { ENABLE_LOCAL_EXEC, PATH_TO_LUNE } = require("../src/config");
const { getSession, openSession } = require("../src/core/sessions");
const { tryRunLocally } = require("../src/local/dispatch");
const { createSseResponder } = require("../src/web/sse");

test("waitUntilReady resolves true once a stream attaches", async () => {
  const responder = createSseResponder(() => {});
  const waited = responder.waitUntilReady();
  responder.attach({ write() {}, on() {}, end() {}, writableEnded: false });
  assert.equal(await waited, true);
  responder.close(); // clears the ping interval so the runner can exit
});

test("waitUntilReady resolves false when the session closes first", async () => {
  const responder = createSseResponder(() => {});
  const waited = responder.waitUntilReady();
  responder.close();
  assert.equal(await waited, false);
});

test("a late attach still resolves true, not false", async () => {
  const responder = createSseResponder(() => {});
  const waited = responder.waitUntilReady();
  await new Promise((resolve) => setTimeout(resolve, 50));
  responder.attach({ write() {}, on() {}, end() {}, writableEnded: false });
  assert.equal(await waited, true);
  responder.close();
});

test(
  "a client that never attaches does not run and does not hold a slot",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `no-attach:${Date.now()}`;
    const responder = createSseResponder(() => {});
    const deliveries = [];
    responder.deliver = async (payload) => deliveries.push(payload);
    // Stands in for the deadline firing 10s after an unattached /run.
    responder.waitUntilReady = () => Promise.resolve(false);
    openSession(token, responder);

    const ranLocally = await tryRunLocally("--!lune\nprint(1)", token, {
      actorKey: token,
    });

    assert.equal(ranLocally, true, "must not fall through to the Roblox queue");
    assert.equal(deliveries.length, 0, "nothing should be delivered");
    assert.equal(getSession(token), undefined, "session should be closed");
  },
);
