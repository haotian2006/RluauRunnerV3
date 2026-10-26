const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const { recordCrash } = require("../src/abuse");
const {
  STUDIO_SESSION_MS,
  WORKER_STREAM_GRACE_MS,
  WORKER_STREAM_PING_TIMEOUT,
} = require("../src/config");
const { hasSession, openSession } = require("../src/core/sessions");
const { registerSessionRoutes } = require("../src/http/routes/session");
const {
  checkServer,
  needsAdditionalWorker,
  reapLostWorker,
} = require("../src/roblox/session");
const {
  ActiveRobloxTasks,
  DispatchedTasks,
  ExecuteTasks,
  RobloxServers,
  attachWorkerStream,
  registerRobloxServer,
  requeueUnstartedTasksForServer,
  reserveNextTask,
  settleTasksForToken,
} = require("../src/state");

let next = 0;
const unique = (name) => `${name}-${Date.now()}-${next++}`;

function studioServer(now = Date.now()) {
  const server = registerRobloxServer(unique("studio"), now);
  server.kind = "studio";
  server.healthy = true;
  return server;
}

// A run handed to `server`; started runs have reported back once.
function run(server, { started = false } = {}) {
  const token = unique("token");
  const taskId = unique("task");
  const actorKey = `web:${unique("actor")}:roblox`;
  const failures = [];
  openSession(token, {
    async fail(error) {
      failures.push(error.message);
    },
    close() {},
  });
  ExecuteTasks[taskId] = { token, actorKey, codeHash: "abc" };
  assert.equal(reserveNextTask(server.serverId), taskId);
  if (started) settleTasksForToken(token, false);
  return { token, taskId, actorKey, failures };
}

function cleanUp() {
  for (const tasks of [ExecuteTasks, DispatchedTasks, ActiveRobloxTasks]) {
    for (const [uuid, entry] of Object.entries(tasks)) {
      clearTimeout(entry?.timer);
      delete tasks[uuid];
    }
  }
  for (const id of Object.keys(RobloxServers)) delete RobloxServers[id];
}

test.afterEach(cleanUp);

test("an open event stream keeps a worker that polls every 10 s healthy", () => {
  const now = Date.now();
  const streamed = studioServer(now - 60_000);
  const polling = studioServer(now - 60_000);
  attachWorkerStream(streamed.serverId, now - 10_000);
  streamed.lastPing = polling.lastPing = now - 10_000;

  checkServer(streamed, now);
  checkServer(polling, now);

  assert.equal(streamed.healthy, true);
  assert.equal(polling.healthy, false);
});

test("an event stream that stops polling for too long still marks the worker unhealthy", () => {
  const now = Date.now();
  const server = studioServer(now - 120_000);
  attachWorkerStream(server.serverId, now - 120_000);
  server.lastPing = now - WORKER_STREAM_PING_TIMEOUT - 1;
  checkServer(server, now);
  assert.equal(server.healthy, false);
});

test("the /workerEvents route ties the stream to the worker's ServerId", () => {
  const server = studioServer();
  let handler;
  registerSessionRoutes({
    get(path, ...handlers) {
      if (path === "/workerEvents") handler = handlers.at(-1);
    },
    post() {},
  });
  const res = Object.assign(new EventEmitter(), {
    writeHead() {},
    write() {},
  });

  handler({ query: { ServerId: server.serverId } }, res);
  assert.equal(server.streams, 1);
  res.emit("close");
  assert.equal(server.streams, 0);
  assert.ok(server.streamLostAt > 0);
});

test("a worker whose stream closes for good is reaped within seconds", async () => {
  const server = studioServer();
  const unstarted = run(server);
  const started = run(server, { started: true });
  attachWorkerStream(server.serverId)();
  const now = server.streamLostAt + WORKER_STREAM_GRACE_MS;

  checkServer(server, now - 1);
  assert.ok(RobloxServers[server.serverId], "kept during the grace period");
  checkServer(server, now);
  assert.equal(RobloxServers[server.serverId], undefined);
  await new Promise((resolve) => setImmediate(resolve));

  // The unstarted run is requeued and its actor not blamed.
  assert.ok(ExecuteTasks[unstarted.taskId]);
  assert.deepEqual(unstarted.failures, []);
  assert.equal(recordCrash(unstarted.actorKey, "another").count, 1);
  // The running one fails at once and costs its actor a strike.
  assert.deepEqual(started.failures, ["Roblox server stopped responding."]);
  assert.equal(hasSession(started.token), false);
  assert.equal(recordCrash(started.actorKey, "another").count, 2);
});

test("a worker that polls after its stream closes is kept", () => {
  const now = Date.now();
  const server = studioServer(now - 60_000);
  attachWorkerStream(server.serverId, now - 60_000)();
  server.streamLostAt = now - 20_000;
  server.lastPing = now - 1_000;

  checkServer(server, now);

  assert.ok(RobloxServers[server.serverId]);
  assert.equal(server.streamLostAt, null);
});

test("a draining Studio session keeps running its tasks until it ends itself", async () => {
  const startedAt = Date.now() - 150_000;
  const server = studioServer(startedAt);
  const going = run(server, { started: true });
  attachWorkerStream(server.serverId, startedAt);
  server.retiring = true;
  server.lastPing = startedAt + 120_000;

  checkServer(server, startedAt + 150_000);
  assert.ok(RobloxServers[server.serverId]);
  assert.deepEqual(going.failures, []);

  checkServer(server, startedAt + STUDIO_SESSION_MS + WORKER_STREAM_GRACE_MS);
  assert.equal(RobloxServers[server.serverId], undefined);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(going.failures, [
    "Session ended.",
  ]);
});

test("a retiring session that just closed its stream gets the grace period, however old its last poll", () => {
  const now = Date.now();
  const server = studioServer(now - 100_000);
  run(server, { started: true });
  server.retiring = true;
  server.lastPing = now - 10_000;
  server.streamLostAt = now - 1_000;

  checkServer(server, now);
  assert.ok(RobloxServers[server.serverId]);
});

test("a draining Studio session that closed its stream lives on its pings", async () => {
  const now = Date.now();
  const server = studioServer(now - 100_000);
  const going = run(server, { started: true });
  attachWorkerStream(server.serverId, now - 30_000)();
  server.retiring = true;
  server.streamLostAt = now - 3_000;
  server.lastPing = now - 2_000;

  checkServer(server, now);
  assert.ok(RobloxServers[server.serverId]);
  assert.equal(server.streamLostAt, null);

  checkServer(server, now + 6_000);
  assert.equal(RobloxServers[server.serverId], undefined);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(going.failures, [
    "Session ended.",
  ]);
});

test("a draining Studio session is let go once its runs finish", () => {
  const server = studioServer(Date.now() - 150_000);
  const going = run(server, { started: true });
  attachWorkerStream(server.serverId);
  server.retiring = true;

  checkServer(server);
  assert.ok(RobloxServers[server.serverId]);
  settleTasksForToken(going.token, true);
  checkServer(server);
  assert.equal(RobloxServers[server.serverId], undefined);
});

test("a session that ends on schedule costs nobody a strike", async () => {
  const server = studioServer();
  const going = run(server, { started: true });
  server.retiring = true;

  await reapLostWorker(server.serverId);

  assert.deepEqual(going.failures, [
    "Session ended.",
  ]);
  assert.equal(recordCrash(going.actorKey, "another").count, 1);
});

test("a run handed to a lost worker is retried once", () => {
  const first = studioServer();
  const handed = run(first);
  assert.deepEqual(requeueUnstartedTasksForServer(first.serverId), {
    requeued: 1,
    exhausted: [],
  });

  const second = studioServer();
  assert.equal(reserveNextTask(second.serverId), handed.taskId);
  const { requeued, exhausted } = requeueUnstartedTasksForServer(
    second.serverId,
  );
  assert.equal(requeued, 0);
  assert.equal(exhausted[0].token, handed.token);
  assert.equal(ExecuteTasks[handed.taskId], undefined);
});

test("a healthy Studio worker takes the sandboxed queue without Open Cloud", () => {
  const studio = { kind: "studio", healthy: true, retiring: false, mode: null };
  const sandboxed = Array.from({ length: 10 }, () => ({}));
  assert.equal(needsAdditionalWorker([studio], sandboxed, 0), false);
});

test("Open Cloud starts when no Studio worker can take the queue", () => {
  const sandboxed = [{}];
  for (const studio of [
    { kind: "studio", healthy: false, retiring: false, mode: null },
    { kind: "studio", healthy: true, retiring: true, mode: null },
  ]) {
    assert.equal(needsAdditionalWorker([studio], sandboxed, 0), true);
  }
  const healthy = { kind: "studio", healthy: true, retiring: false, mode: null };
  assert.equal(needsAdditionalWorker([healthy], [{ nosandbox: true }], 0), true);
});
