const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_LUNE } = require("../src/config");
const { getSession } = require("../src/core/sessions");
const { POLL_RATE_LIMIT } = require("../src/web/rateLimit");
const {
  POLL_GRACE_MS,
  registerWebRoutes,
  sweepPollSessions,
} = require("../src/web");

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
    contentType: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    type(value) {
      this.contentType = value;
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

let nextIp = 100;
function ip() {
  nextIp += 1;
  return `10.1.0.${nextIp}`;
}

const routes = routesForTest();

async function poll(token, caller) {
  const res = responseForTest();
  await routes.GET["/result/:token"]({ ip: caller, params: { token } }, res);
  return res;
}

test("an unknown token is a 404", async () => {
  const res = await poll("nope", ip());
  assert.equal(res.statusCode, 404);
});

test(
  "a stream:false run is readable by polling, and survives the session",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 30_000 },
  async () => {
    const caller = ip();
    const started = responseForTest();
    await routes.POST["/run"](
      { ip: caller, body: { code: "print('polled')", stream: false } },
      started,
    );
    assert.equal(started.statusCode, 200);
    const { token } = started.body;
    assert.ok(token);

    let last;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      last = await poll(token, caller);
      assert.equal(last.statusCode, 200);
      if (last.body.status !== "running") break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    assert.equal(last.body.status, "done");
    assert.match(last.body.content, /polled/);

    // The session is torn down once the run ends; the snapshot is not.
    assert.equal(getSession(token), undefined);
    const afterwards = await poll(token, caller);
    assert.equal(afterwards.statusCode, 200);
    assert.equal(afterwards.body.status, "done");
    assert.match(afterwards.body.content, /polled/);
  },
);

test("polling is capped per ip", async () => {
  const caller = ip();
  for (let i = 0; i < POLL_RATE_LIMIT; i++) {
    assert.equal((await poll("nope", caller)).statusCode, 404);
  }
  assert.equal((await poll("nope", caller)).statusCode, 429);
});

test(
  "a poll session that stops being polled is torn down",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 30_000 },
  async () => {
    const caller = ip();
    const started = responseForTest();
    await routes.POST["/run"](
      { ip: caller, body: { code: "while true do end", stream: false } },
      started,
    );
    const { token } = started.body;
    assert.ok(getSession(token));

    sweepPollSessions(Date.now());
    assert.ok(getSession(token), "still polled recently, so still alive");

    sweepPollSessions(Date.now() + POLL_GRACE_MS + 1);
    assert.equal(getSession(token), undefined);

    // The run is gone, but its last state is still collectable.
    const res = await poll(token, caller);
    assert.equal(res.statusCode, 200);
    assert.equal(res.body.status, "closed");
    assert.equal(res.body.error, "Client stopped polling");
  },
);
