const test = require("node:test");
const assert = require("node:assert/strict");

const {
  ExecuteTasks,
  RobloxServers,
  dispatchTask,
  getDispatchedTask,
  getUnfinishedTasksForServer,
  registerRobloxServer,
  reserveNextTask,
  settleTasksForToken,
  state,
  takeUnfinishedTasksForServer,
  unregisterRobloxServer,
} = require("../src/state");

test("only unfinished tasks from the crashed server are returned", () => {
  const serverId = `server:${Date.now()}`;
  state.RunningServer = serverId;

  ExecuteTasks.active = { token: "active", actorKey: "discord:a" };
  dispatchTask("active");
  settleTasksForToken("active", false);

  ExecuteTasks.finished = { token: "finished", actorKey: "discord:b" };
  dispatchTask("finished");
  settleTasksForToken("finished", false);
  settleTasksForToken("finished", true);

  assert.deepEqual(getUnfinishedTasksForServer(serverId), [
    { token: "active", actorKey: "discord:a" },
  ]);
  assert.deepEqual(getUnfinishedTasksForServer(serverId), [
    { token: "active", actorKey: "discord:a" },
  ]);

  const unfinished = takeUnfinishedTasksForServer(serverId);
  assert.deepEqual(unfinished, [
    { token: "active", actorKey: "discord:a" },
  ]);
  assert.deepEqual(takeUnfinishedTasksForServer(serverId), []);
});

test("a responsive Roblox worker can accept another yielding task", () => {
  const firstServer = `worker:first:${Date.now()}`;
  const secondServer = `worker:second:${Date.now()}`;
  registerRobloxServer(firstServer);
  registerRobloxServer(secondServer);

  ExecuteTasks.poolA = { token: "pool-a" };
  ExecuteTasks.poolB = { token: "pool-b" };
  ExecuteTasks.poolC = { token: "pool-c" };

  assert.equal(reserveNextTask(firstServer), "poolA");
  assert.equal(reserveNextTask(firstServer), "poolB");
  assert.deepEqual(getDispatchedTask("poolA"), { token: "pool-a" });

  // An initial response keeps attribution without preventing the healthy
  // worker from accepting another task on its next poll.
  settleTasksForToken("pool-a", false);
  assert.equal(reserveNextTask(firstServer), "poolC");
  assert.deepEqual(
    [...RobloxServers[firstServer].activeTaskIds],
    ["poolA", "poolB", "poolC"],
  );

  settleTasksForToken("pool-a", true);
  settleTasksForToken("pool-b", true);
  settleTasksForToken("pool-c", true);
  assert.equal(RobloxServers[firstServer].activeTaskIds.size, 0);
  unregisterRobloxServer(firstServer);
  unregisterRobloxServer(secondServer);
  assert.equal(RobloxServers[firstServer], undefined);
  assert.equal(RobloxServers[secondServer], undefined);
});
