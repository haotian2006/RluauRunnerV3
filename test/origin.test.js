const test = require("node:test");
const assert = require("node:assert/strict");

const {
  ROBLOX_KEY,
  isRobloxOrigin,
  limiterKey,
  noteWorkerIp,
  resetWorkerIps,
} = require("../src/origin");
const { requireSecret } = require("../src/http/middleware");
const { SECRET_TOKEN } = require("../src/state");
const { registerWebRoutes } = require("../src/web");

function routesForTest() {
  const routes = { GET: {}, POST: {} };
  const app = {
    set() {},
    get(path, ...handlers) {
      routes.GET[path] = handlers.at(-1);
    },
    post(path, ...handlers) {
      routes.POST[path] = handlers.at(-1);
    },
  };
  registerWebRoutes(app);
  return routes;
}

function responseForTest() {
  return {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    type() {
      return this;
    },
    setHeader() {},
    json(body) {
      this.body = body;
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    },
  };
}

const ROBLOX_AGENT = "Roblox/Linux";

test("the roblox user agent is one caller, whatever the address", () => {
  resetWorkerIps();
  const a = { ip: "128.116.0.1", headers: { "user-agent": ROBLOX_AGENT } };
  const b = { ip: "203.0.113.9", headers: { "user-agent": ROBLOX_AGENT } };

  assert.equal(limiterKey(a), ROBLOX_KEY);
  assert.equal(limiterKey(b), ROBLOX_KEY);
});

test("everyone else is still counted by address", () => {
  resetWorkerIps();
  const browser = { ip: "203.0.113.9", headers: { "user-agent": "Mozilla/5.0" } };
  assert.equal(limiterKey(browser), "203.0.113.9");
  assert.equal(isRobloxOrigin(browser), false);
});

test("an address the worker pool authenticated from joins the roblox bucket", () => {
  resetWorkerIps();
  const plain = { ip: "128.116.4.7", headers: {} };
  assert.equal(limiterKey(plain), "128.116.4.7");

  noteWorkerIp("128.116.4.7");
  assert.equal(limiterKey(plain), ROBLOX_KEY);

  // Its neighbours in the same /24 come with it.
  assert.equal(limiterKey({ ip: "128.116.4.200", headers: {} }), ROBLOX_KEY);
  assert.equal(limiterKey({ ip: "128.116.5.200", headers: {} }), "128.116.5.200");
});

test("requireSecret is what teaches the bucket where the pool lives", () => {
  resetWorkerIps();
  const req = {
    ip: "::ffff:128.116.9.9",
    headers: { "x-secret-token": SECRET_TOKEN },
  };
  let passed = false;
  requireSecret(req, responseForTest(), () => {
    passed = true;
  });
  assert.equal(passed, true);
  // The v6-mapped form is stored as the v4 address it actually is.
  assert.equal(limiterKey({ ip: "128.116.9.9", headers: {} }), ROBLOX_KEY);
});

test("a wrong secret teaches it nothing", () => {
  resetWorkerIps();
  const res = responseForTest();
  requireSecret(
    { ip: "198.51.100.4", headers: { "x-secret-token": "nope" } },
    res,
    () => assert.fail("should not pass"),
  );
  assert.equal(res.statusCode, 403);
  assert.equal(limiterKey({ ip: "198.51.100.4", headers: {} }), "198.51.100.4");
});

test("two roblox servers spend one budget on the public api", async () => {
  resetWorkerIps();
  const routes = routesForTest();

  const first = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: "128.116.1.1",
      headers: { "user-agent": ROBLOX_AGENT },
      body: { code: "print(1)" },
    },
    first,
  );
  assert.equal(first.statusCode, 200);

  // A different Roblox address entirely, and it is already out of budget.
  const second = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: "52.10.20.30",
      headers: { "user-agent": ROBLOX_AGENT },
      body: { code: "print(1)" },
    },
    second,
  );
  assert.equal(second.statusCode, 429);

  // A browser is unaffected by what Roblox has been doing.
  const browser = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: "198.51.100.77",
      headers: { "user-agent": "Mozilla/5.0" },
      body: { code: "print(1)" },
    },
    browser,
  );
  assert.equal(browser.statusCode, 200);
});
