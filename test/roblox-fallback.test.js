const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { encodeZstd } = require("../src/chunks");
const { ENABLE_LOCAL_EXEC, PATH_TO_LUNE } = require("../src/config");
const { hasSession, openSession } = require("../src/core/sessions");
const {
  failPendingTasks,
  fallbackPendingTasksToLune,
  luneActorKey,
} = require("../src/roblox/session");
const { ExecuteTasks } = require("../src/state");

test("Roblox actor keys switch to their separate Lune scope", () => {
  assert.equal(luneActorKey("discord:user:roblox"), "discord:user:lune");
  assert.equal(luneActorKey("web:hash:roblox"), "web:hash:lune");
});

test("failed Roblox startup rejects queued web sessions", async () => {
  const token = `web-failure-${Date.now()}`;
  const taskId = `web-failure-task-${Date.now()}`;
  const failures = [];
  let closed = false;

  openSession(token, {
    async fail(error) {
      failures.push(error.message);
    },
    close() {
      closed = true;
    },
  });
  ExecuteTasks[taskId] = { token, isWeb: true };

  await failPendingTasks();

  assert.deepEqual(failures, ["Failed to start."]);
  assert.equal(ExecuteTasks[taskId], undefined);
  assert.equal(hasSession(token), false);
  assert.equal(closed, true);
});

test(
  "queued Roblox work falls back through the existing Lune session",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `fallback-${Date.now()}`;
    const taskId = `fallback-task-${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });
    ExecuteTasks[taskId] = {
      token,
      actorKey: `discord:fallback-${Date.now()}:roblox`,
      content: encodeZstd("print(42)"),
      isWeb: false,
    };

    await fallbackPendingTasksToLune();

    assert.equal(ExecuteTasks[taskId], undefined);
    assert.equal(deliveries.at(-1).serverNum, "Lune");
    assert.match(deliveries.at(-1).responseContent, /42/);
  },
);
