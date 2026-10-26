const test = require("node:test");
const assert = require("node:assert/strict");

const { STUDIO_ACCEPT_MS, STUDIO_DRAIN_MS, STUDIO_SESSION_MS } = require("../src/config");
const { registerSessionRoutes } = require("../src/http/routes/session");
const {
  ExecuteTasks,
  RobloxServers,
  dispatchTask,
  serverForToken,
  settleTasksForToken,
  state,
} = require("../src/state");

function routes() {
  const found = {};
  registerSessionRoutes({
    get() {},
    post(path, ...handlers) {
      found[path] = handlers.at(-1);
    },
  });
  return found;
}

function response() {
  const res = { statusCode: 200, body: undefined };
  res.status = (code) => {
    res.statusCode = code;
    return res;
  };
  res.json = (body) => {
    res.body = body;
    return res;
  };
  res.end = () => res;
  return res;
}

function clearServers() {
  for (const id of Object.keys(RobloxServers)) delete RobloxServers[id];
}

test("a worker from the worker socket registers as a Studio worker", async () => {
  clearServers();
  await routes()["/start"]({ body: { ServerId: "studio-a" }, studioWorker: true }, response());
  await routes()["/start"]({ body: { ServerId: "cloud-a" } }, response());
  assert.equal(RobloxServers["studio-a"].kind, "studio");
  assert.equal(RobloxServers["cloud-a"].kind, "cloud");
  clearServers();
});

test("Studio workers neither fill the cloud pool nor take a pending cloud start", async () => {
  clearServers();
  state.PendingRobloxStarts.push({ profileName: "test", createdAt: Date.now() });
  for (let i = 0; i < 20; i++) {
    const res = response();
    await routes()["/start"]({ body: { ServerId: `studio-${i}` }, studioWorker: true }, res);
    assert.notEqual(res.statusCode, 429);
  }
  assert.equal(state.PendingRobloxStarts.length, 1);
  state.PendingRobloxStarts.length = 0;
  clearServers();
});

async function poll(serverId) {
  const res = response();
  await routes()["/getNext"]({ body: { ServerId: serverId } }, res);
  return res.statusCode;
}

test("a Studio session past the accept window hands over to a younger one taking tasks", async () => {
  clearServers();
  await routes()["/start"]({ body: { ServerId: "studio-old" }, studioWorker: true }, response());
  RobloxServers["studio-old"].startedAt = Date.now() - STUDIO_ACCEPT_MS - 1000;
  // Alone, it keeps taking tasks.
  assert.equal(await poll("studio-old"), 204);
  assert.equal(RobloxServers["studio-old"].retiring, false);

  await routes()["/start"]({ body: { ServerId: "studio-young" }, studioWorker: true }, response());
  assert.equal(await poll("studio-young"), 204);
  assert.equal(await poll("studio-old"), 201);
  assert.equal(RobloxServers["studio-old"].retiring, true);
  // The younger one is unaffected.
  assert.equal(await poll("studio-young"), 204);
  clearServers();
});

test("a lone Studio session stops taking tasks in time for its runs to finish", async () => {
  clearServers();
  await routes()["/start"]({ body: { ServerId: "studio-alone" }, studioWorker: true }, response());
  RobloxServers["studio-alone"].startedAt = Date.now() - (STUDIO_SESSION_MS - STUDIO_DRAIN_MS);
  assert.equal(await poll("studio-alone"), 201);
  assert.equal(RobloxServers["studio-alone"].retiring, true);
  clearServers();
});

test("a young Studio worker keeps taking tasks", async () => {
  clearServers();
  await routes()["/start"]({ body: { ServerId: "studio-new" }, studioWorker: true }, response());
  const res = response();
  await routes()["/getNext"]({ body: { ServerId: "studio-new" } }, res);
  assert.equal(res.statusCode, 204);
  assert.equal(RobloxServers["studio-new"].retiring, false);
  clearServers();
});

test("a run is traced to the Studio worker running it until it finishes", async () => {
  clearServers();
  await routes()["/start"]({ body: { ServerId: "studio-run" }, studioWorker: true }, response());
  ExecuteTasks["task-studio"] = { token: "token-studio", actorKey: "web:a" };
  dispatchTask("task-studio", "studio-run");
  assert.equal(serverForToken("token-studio")?.kind, "studio");
  settleTasksForToken("token-studio", false);
  assert.equal(serverForToken("token-studio")?.kind, "studio");
  settleTasksForToken("token-studio", true);
  assert.equal(serverForToken("token-studio"), null);
  clearServers();
});
