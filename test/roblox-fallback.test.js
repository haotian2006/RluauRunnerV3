const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { encodeZstd } = require("../src/chunks");
const { ENABLE_LOCAL_EXEC, PATH_TO_LUNE } = require("../src/config");
const { openSession } = require("../src/core/sessions");
const {
  fallbackPendingTasksToLune,
  luneActorKey,
} = require("../src/roblox/session");
const { ExecuteTasks } = require("../src/state");

test("Roblox actor keys switch to their separate Lune scope", () => {
  assert.equal(
    luneActorKey("discord:user:roblox"),
    "discord:user:lune",
  );
  assert.equal(luneActorKey("web:hash:roblox"), "web:hash:lune");
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
