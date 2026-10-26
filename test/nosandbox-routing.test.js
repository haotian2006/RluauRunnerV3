const test = require("node:test");
const assert = require("node:assert/strict");

const { parseHotComments } = require("../src/local/hotComments");
const { needsAdditionalWorker } = require("../src/roblox/session");
const {
  ExecuteTasks,
  RobloxServers,
  registerRobloxServer,
  reserveNextTask,
  settleTasksForToken,
  unregisterRobloxServer,
} = require("../src/state");

test("--!nosandbox is only read from the leading hot comments", () => {
  assert.equal(parseHotComments("--!nosandbox\nprint(1)").nosandbox, true);
  assert.equal(parseHotComments("--!native\n--!nosandbox\nprint(1)").nosandbox, true);
  assert.equal(parseHotComments('print("--!nosandbox")').nosandbox, false);
  assert.equal(parseHotComments("print(1)\n--!nosandbox").nosandbox, false);
});

test("a server only takes tasks of the mode it started with", () => {
  const server = `mode:${Date.now()}`;
  registerRobloxServer(server);

  ExecuteTasks.modeNo = { token: "mode-no", nosandbox: true };
  ExecuteTasks.modeYes = { token: "mode-yes" };

  assert.equal(reserveNextTask(server), "modeNo");
  assert.equal(RobloxServers[server].mode, "nosandbox");
  // The sandboxed task stays queued for a sandbox server.
  assert.equal(reserveNextTask(server), null);
  assert.ok(ExecuteTasks.modeYes);

  const other = `mode:other:${Date.now()}`;
  registerRobloxServer(other);
  assert.equal(reserveNextTask(other), "modeYes");
  assert.equal(RobloxServers[other].mode, "sandbox");

  settleTasksForToken("mode-no", true);
  settleTasksForToken("mode-yes", true);
  unregisterRobloxServer(server);
  unregisterRobloxServer(other);
});

test("a queued nosandbox task starts a worker when only sandbox servers exist", () => {
  const workers = [{ healthy: true, retiring: false, mode: "sandbox" }];
  assert.equal(needsAdditionalWorker(workers, [{ nosandbox: true }], 0), true);
  assert.equal(needsAdditionalWorker(workers, [{}], 0), false);
});

test("an unused server can take either kind", () => {
  const workers = [{ healthy: true, retiring: false, mode: null }];
  assert.equal(needsAdditionalWorker(workers, [{ nosandbox: true }], 0), false);
  assert.equal(needsAdditionalWorker(workers, [{}], 0), false);
});

test("a headless Studio worker never takes a nosandbox task", () => {
  const studio = `studio:${Date.now()}`;
  registerRobloxServer(studio).kind = "studio";
  ExecuteTasks.studioNo = { token: "studio-no", nosandbox: true };

  assert.equal(reserveNextTask(studio), null);
  assert.ok(ExecuteTasks.studioNo);
  assert.equal(RobloxServers[studio].mode, null);

  ExecuteTasks.studioYes = { token: "studio-yes" };
  assert.equal(reserveNextTask(studio), "studioYes");

  delete ExecuteTasks.studioNo;
  settleTasksForToken("studio-yes", true);
  unregisterRobloxServer(studio);
});

test("Studio workers don't count toward serving queued nosandbox tasks", () => {
  const workers = [{ healthy: true, retiring: false, mode: null, kind: "studio" }];
  assert.equal(needsAdditionalWorker(workers, [{ nosandbox: true }], 0), true);
  assert.equal(needsAdditionalWorker(workers, [{}], 0), false);
});
