const test = require("node:test");
const assert = require("node:assert/strict");

const { CRASHES_BEFORE_BLOCK, recordCrash } = require("../src/abuse");
const { openSession } = require("../src/core/sessions");
const { registerSessionRoutes } = require("../src/http/routes/session");
const {
  ExecuteTasks,
  RobloxServers,
  registerRobloxServer,
  settleTasksForToken,
  touchRobloxServer,
  unregisterRobloxServer,
} = require("../src/state");

function routesForTest() {
  const routes = {};
  const app = {
    get() {},
    post(path, ...handlers) {
      routes[path] = handlers.at(-1);
    },
  };
  registerSessionRoutes(app);
  return routes;
}

function responseForTest() {
  return {
    statusCode: 200,
    body: null,
    ended: false,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
    end() {
      this.ended = true;
      return this;
    },
  };
}

test("getNext atomically reserves and returns one task", async () => {
  const routes = routesForTest();
  const serverId = `get-next:${Date.now()}`;
  registerRobloxServer(serverId);
  touchRobloxServer(serverId);
  ExecuteTasks.nextTask = { token: "next-token", content: "encoded" };

  const first = responseForTest();
  await routes["/getNext"]({ body: { ServerId: serverId } }, first);
  assert.equal(first.statusCode, 200);
  assert.deepEqual(first.body, { token: "next-token", content: "encoded" });
  assert.equal(ExecuteTasks.nextTask, undefined);

  const empty = responseForTest();
  await routes["/getNext"]({ body: { ServerId: serverId } }, empty);
  assert.equal(empty.statusCode, 204);
  assert.equal(empty.ended, true);

  settleTasksForToken("next-token", true);
  unregisterRobloxServer(serverId);
});

test("getNext drops a newly blocked queued task before dispatch", async () => {
  const routes = routesForTest();
  const serverId = `blocked-queue:${Date.now()}`;
  const actorKey = `discord:blocked-queue-${Date.now()}:roblox`;
  const blockedToken = `blocked-token-${Date.now()}`;
  registerRobloxServer(serverId);
  touchRobloxServer(serverId);

  for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
    recordCrash(actorKey, `blocked-queue-crash:${index}`);
  }

  let failure = null;
  openSession(blockedToken, {
    async fail(error) {
      failure = error.message;
    },
    close() {},
  });
  ExecuteTasks.blockedQueueTask = {
    token: blockedToken,
    actorKey,
    content: "blocked",
  };
  ExecuteTasks.allowedQueueTask = {
    token: "allowed-token",
    actorKey: `discord:allowed-${Date.now()}:roblox`,
    content: "allowed",
  };

  const response = responseForTest();
  await routes["/getNext"]({ body: { ServerId: serverId } }, response);

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.content, "allowed");
  assert.equal(ExecuteTasks.blockedQueueTask, undefined);
  assert.match(failure, /^Failed to start\. Try again in \d+ seconds\.$/);

  settleTasksForToken("allowed-token", true);
  unregisterRobloxServer(serverId);
});

test("legacy getAll and get remain available during rollout", async () => {
  const routes = routesForTest();
  const serverId = `get-all:${Date.now()}`;
  registerRobloxServer(serverId);
  touchRobloxServer(serverId);
  ExecuteTasks.legacyTask = { token: "legacy-token", content: "encoded" };

  const list = responseForTest();
  await routes["/getAll"]({ body: { ServerId: serverId } }, list);
  assert.deepEqual(list.body, ["legacyTask"]);

  const task = responseForTest();
  await routes["/get"]({ body: { TaskId: "legacyTask" } }, task);
  assert.deepEqual(task.body, {
    token: "legacy-token",
    content: "encoded",
  });

  settleTasksForToken("legacy-token", true);
  unregisterRobloxServer(serverId);
});

test("the next getNext heartbeat restores an unhealthy worker", async () => {
  const routes = routesForTest();
  const serverId = `recovered:${Date.now()}`;
  registerRobloxServer(serverId);
  const server = RobloxServers[serverId];
  server.healthy = false;
  server.unhealthySince = Date.now() - 10_000;
  server.outageRecorded = true;
  ExecuteTasks.recoveredTask = {
    token: "recovered-token",
    content: "encoded",
  };

  const response = responseForTest();
  await routes["/getNext"]({ body: { ServerId: serverId } }, response);

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.token, "recovered-token");
  assert.equal(server.healthy, true);
  assert.equal(server.unhealthySince, null);
  assert.equal(server.outageRecorded, false);

  settleTasksForToken("recovered-token", true);
  unregisterRobloxServer(serverId);
});

test("an expired unhealthy worker is told to close instead of rejoining", async () => {
  const routes = routesForTest();
  const serverId = `expired:${Date.now()}`;
  registerRobloxServer(serverId, Date.now() - 181_000);
  ExecuteTasks.expiredTask = {
    token: "expired-token",
    content: "encoded",
  };

  const response = responseForTest();
  await routes["/getNext"]({ body: { ServerId: serverId } }, response);

  assert.equal(response.statusCode, 201);
  assert.equal(RobloxServers[serverId].retiring, true);
  assert.ok(ExecuteTasks.expiredTask);

  delete ExecuteTasks.expiredTask;
  unregisterRobloxServer(serverId);
});
