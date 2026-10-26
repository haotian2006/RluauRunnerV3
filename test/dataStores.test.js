const fs = require("fs");
const os = require("os");
const path = require("path");

const DIR = fs.mkdtempSync(path.join(os.tmpdir(), "datastores-test-"));
process.env.DATASTORE_DIR = DIR;
process.env.DATASTORE_QUOTA_BYTES = "2048";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  entryBytes,
  grantStorage,
  loadUserData,
  saveUserData,
  sweepDataStores,
  userForToken,
} = require("../src/dataStores");
const { registerDataStoreRoutes } = require("../src/http/routes/dataStores");
const { registerSessionRoutes } = require("../src/http/routes/session");
const { SECRET_TOKEN } = require("../src/state");

const entry = (v, extra = {}) => ({ v: JSON.stringify([v]), version: "0000000000000001", created: 1, updated: 1, ...extra });

function routesFor(register) {
  const routes = {};
  register({
    get() {},
    post(route, ...handlers) {
      routes[route] = handlers;
    },
  });
  return routes;
}

async function call(handlers, headers, body) {
  const res = {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(value) {
      this.body = value;
      return this;
    },
    end() {
      return this;
    },
  };
  const req = { headers, body, ip: "127.0.0.1" };
  for (const handler of handlers) {
    let next = false;
    await handler(req, res, () => {
      next = true;
    });
    if (!next) break;
  }
  return res;
}

test("only sandboxed Discord runs get a storage token, kept across retries", () => {
  assert.equal(grantStorage({ userId: "123", isWeb: true }), null);
  assert.equal(grantStorage({ userId: "123", nosandbox: true }), null);
  assert.equal(grantStorage({ userId: "web-token-abc" }), null);
  const task = { userId: "123" };
  const token = grantStorage(task);
  assert.match(token, /^[\w-]{32}$/);
  assert.equal(task.storageToken, token);
  assert.equal(grantStorage(task), token);
  assert.equal(userForToken(token), "123");
  assert.equal(userForToken("forged"), null);
  assert.equal(userForToken(token, Date.now() + 10 * 60 * 60 * 1000), null);
  assert.equal(userForToken(token), null, "an expired token is forgotten");
});

test("changes merge key by key and survive a reload", async () => {
  const user = "1001";
  assert.deepEqual((await loadUserData(user)).entries, {});
  let reply = await saveUserData(user, [
    { store: "d\0Coins\0global", key: "a", entry: entry(5) },
    { store: "d\0Coins\0global", key: "b", entry: entry({ x: 1 }) },
  ]);
  assert.equal(reply.status, 200);
  reply = await saveUserData(user, [
    { store: "d\0Coins\0global", key: "a" },
    { store: "h\0Map", key: "k", entry: entry("hi", { expiresAt: Date.now() + 60000, junk: "dropped" }) },
  ]);
  assert.equal(reply.status, 200);
  const loaded = await loadUserData(user);
  assert.deepEqual(Object.keys(loaded.entries["d\0Coins\0global"]), ["b"]);
  assert.equal(loaded.entries["h\0Map"].k.junk, undefined);
  assert.equal(loaded.used, reply.used);
  assert.equal(loaded.quota, 2048);
  assert.equal(
    loaded.used,
    entryBytes("d\0Coins\0global", "b", loaded.entries["d\0Coins\0global"].b) +
      entryBytes("h\0Map", "k", loaded.entries["h\0Map"].k),
  );
  const file = JSON.parse(fs.readFileSync(path.join(DIR, `${user}.json`), "utf8"));
  assert.ok(file.entries["d\0Coins\0global"].b);
});

test("expired MemoryStore records are dropped", async () => {
  const user = "1002";
  await saveUserData(user, [
    { store: "q\0Jobs", key: "1", entry: entry(1, { expiresAt: Date.now() - 1 }) },
    { store: "q\0Jobs", key: "2", entry: entry(2, { expiresAt: Date.now() + 60000, priority: 1, order: 5, hiddenUntil: 0 }) },
  ]);
  const loaded = await loadUserData(user);
  assert.deepEqual(Object.keys(loaded.entries["q\0Jobs"]), ["2"]);
  assert.equal(loaded.entries["q\0Jobs"]["2"].priority, 1);
});

test("over the quota nothing is written; malformed changes are refused", async () => {
  const user = "1003";
  await saveUserData(user, [{ store: "d\0S\0global", key: "small", entry: entry(1) }]);
  const big = await saveUserData(user, [
    { store: "d\0S\0global", key: "small" },
    { store: "d\0S\0global", key: "big", entry: entry("x".repeat(3000)) },
  ]);
  assert.equal(big.status, 413);
  assert.match(big.message, /over the 2 KB limit/);
  assert.ok((await loadUserData(user)).entries["d\0S\0global"].small, "the batch was not half-applied");

  for (const bad of [
    "nope",
    [{ store: "d\0S\0global", key: "", entry: entry(1) }],
    [{ store: "d\0S\0global", key: "k".repeat(51), entry: entry(1) }],
    [{ store: "d\0S\0global", key: "k", entry: { v: 5 } }],
    [{ store: "d\0S\0global", key: "k", entry: entry(1, { metadata: "m".repeat(301) }) }],
    [{ store: "d\0S\0global", key: "k", entry: entry(1, { userIds: [1, 2, 3, 4, 5] }) }],
    [{ store: "d\0S\0global", key: "k", entry: entry(1, { expiresAt: "soon" }) }],
  ]) {
    assert.equal((await saveUserData(user, bad)).status, 400, JSON.stringify(bad));
  }
});

test("writes from one user apply in order", async () => {
  const user = "1004";
  await Promise.all(
    Array.from({ length: 20 }, (_, i) => saveUserData(user, [{ store: "d\0S\0global", key: "n", entry: entry(i) }])),
  );
  assert.equal((await loadUserData(user)).entries["d\0S\0global"].n.v, JSON.stringify([19]));
});

test("unused data expires", async () => {
  const user = "1005";
  await saveUserData(user, [{ store: "d\0S\0global", key: "k", entry: entry(1) }]);
  const old = new Date(Date.now() - 31 * 24 * 60 * 60 * 1000);
  fs.utimesSync(path.join(DIR, `${user}.json`), old, old);
  assert.equal(await sweepDataStores(), 1);
  assert.deepEqual((await loadUserData(user)).entries, {});
});

test("routes need the worker secret and a live storage token", async () => {
  const routes = routesFor(registerDataStoreRoutes);
  const token = grantStorage({ userId: "1006" });
  const headers = { "x-secret-token": SECRET_TOKEN, "x-storage-token": token };

  assert.equal((await call(routes["/dataStore/load"], { "x-storage-token": token })).statusCode, 403);
  assert.equal((await call(routes["/dataStore/load"], { "x-secret-token": SECRET_TOKEN })).statusCode, 403);

  const saved = await call(routes["/dataStore/save"], headers, {
    changes: [{ store: "d\0S\0global", key: "k", entry: entry(7) }],
  });
  assert.equal(saved.statusCode, 200);
  const loaded = await call(routes["/dataStore/load"], headers);
  assert.equal(loaded.body.entries["d\0S\0global"].k.v, "[7]");
  const bad = await call(routes["/dataStore/save"], headers, { changes: {} });
  assert.equal(bad.statusCode, 400);
});

test("the worker payload carries the token for sandboxed Discord runs only", async () => {
  const { ExecuteTasks, registerRobloxServer, settleTasksForToken, unregisterRobloxServer } = require("../src/state");
  const routes = routesFor(registerSessionRoutes);
  registerRobloxServer("ds-worker");
  ExecuteTasks["ds-task"] = { content: "x", token: "t1", userId: "1007", actorKey: "discord:1007" };
  const res = await call(routes["/getNext"], { "x-secret-token": SECRET_TOKEN }, { ServerId: "ds-worker" });
  assert.equal(userForToken(res.body.storageToken), "1007");
  ExecuteTasks["ds-web"] = { content: "x", token: "t2", userId: "t2", isWeb: true, actorKey: "web:1" };
  const web = await call(routes["/getNext"], { "x-secret-token": SECRET_TOKEN }, { ServerId: "ds-worker" });
  assert.equal(web.body.storageToken, undefined);
  settleTasksForToken("t1");
  settleTasksForToken("t2");
  unregisterRobloxServer("ds-worker");
});

test.after(() => fs.rmSync(DIR, { recursive: true, force: true }));
