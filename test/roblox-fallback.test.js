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
  reapRobloxServer,
} = require("../src/roblox/session");
const {
  ActiveRobloxTasks,
  ExecuteTasks,
  RobloxServers,
  registerRobloxServer,
  reserveNextTask,
  settleTasksForToken,
} = require("../src/state");

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

test("a task stranded on a reaped server is failed, not dropped", async () => {
  const token = `reaped-${Date.now()}`;
  const taskId = `reaped-task-${Date.now()}`;
  const serverId = `reaped-server-${Date.now()}`;
  const failures = [];
  let closed = false;
  let finishFailure;
  const slowFailure = new Promise((resolve) => {
    finishFailure = resolve;
  });

  openSession(token, {
    async fail(error) {
      failures.push(error.message);
      await slowFailure;
    },
    close() {
      closed = true;
    },
  });

  registerRobloxServer(serverId);
  ExecuteTasks[taskId] = { token, isWeb: true };
  reserveNextTask(serverId);

  const notifications = reapRobloxServer(serverId);

  assert.equal(RobloxServers[serverId], undefined);
  assert.deepEqual(failures, ["Roblox server stopped responding."]);
  finishFailure();
  await notifications;
  assert.equal(hasSession(token), false);
  assert.equal(closed, true);
});

test("an active task on a reaped server is failed and removed", async () => {
  const token = `reaped-active-${Date.now()}`;
  const taskId = `reaped-active-task-${Date.now()}`;
  const serverId = `reaped-active-server-${Date.now()}`;
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

  registerRobloxServer(serverId);
  ExecuteTasks[taskId] = { token, isWeb: true };
  reserveNextTask(serverId);
  settleTasksForToken(token, false);
  assert.equal(ActiveRobloxTasks[taskId]?.task.token, token);

  await reapRobloxServer(serverId);

  assert.equal(ActiveRobloxTasks[taskId], undefined);
  assert.equal(RobloxServers[serverId], undefined);
  assert.deepEqual(failures, ["Roblox server stopped responding."]);
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
