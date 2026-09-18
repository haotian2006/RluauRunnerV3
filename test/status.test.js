process.env.STATS_PASSWORD = "correct-horse-battery";

const test = require("node:test");
const assert = require("node:assert/strict");

const metrics = require("../src/metrics");
const auth = require("../src/http/statusAuth");
const { registerStatusRoutes } = require("../src/http/routes/status");

function routesForTest() {
  const routes = { GET: {}, POST: {} };
  const app = {
    get(path, ...handlers) {
      routes.GET[path] = handlers.at(-1);
    },
    post(path, ...handlers) {
      routes.POST[path] = handlers.at(-1);
    },
  };
  registerStatusRoutes(app);
  return routes;
}

function responseForTest() {
  return {
    statusCode: 200,
    body: null,
    headers: {},
    redirectedTo: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    type(value) {
      this.headers["Content-Type"] = value;
      return this;
    },
    setHeader(name, value) {
      this.headers[name] = value;
    },
    removeHeader(name) {
      delete this.headers[name];
    },
    json(body) {
      this.body = body;
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    },
    redirect(code, location) {
      this.statusCode = code;
      this.redirectedTo = location;
      return this;
    },
  };
}

function cookieFrom(res) {
  return String(res.headers["Set-Cookie"]).split(";")[0];
}

const routes = routesForTest();

test("the page is registered only when a password is configured", () => {
  assert.ok(routes.GET["/status"], "password is set in this file");
});

test("without a session the page asks for the password and shows no data", () => {
  auth.reset();
  const res = responseForTest();
  routes.GET["/status"]({ headers: {}, query: {} }, res);

  assert.equal(res.statusCode, 401);
  assert.match(res.body, /type="password"/);
  assert.doesNotMatch(res.body, /Worker pool/);
  // Nothing about this page is for another origin, or for a cache.
  assert.equal(res.headers["Access-Control-Allow-Origin"], undefined);
  assert.equal(res.headers["Cache-Control"], "private, no-store");
  assert.equal(res.headers["X-Frame-Options"], "DENY");
});

test("the wrong password is refused and hands out no cookie", () => {
  auth.reset();
  const res = responseForTest();
  routes.POST["/status/login"](
    { ip: "203.0.113.1", headers: {}, body: { password: "guess" } },
    res,
  );

  assert.equal(res.statusCode, 401);
  assert.equal(res.headers["Set-Cookie"], undefined);
  assert.match(res.body, /Incorrect password/);
});

test("the right password opens a session that the page accepts", () => {
  auth.reset();
  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.2",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );

  assert.equal(login.statusCode, 303);
  assert.equal(login.redirectedTo, "/status");
  const cookie = String(login.headers["Set-Cookie"]);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);

  const res = responseForTest();
  routes.GET["/status"]({ headers: { cookie: cookieFrom(login) }, query: {} }, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Worker pool/);
  assert.match(res.body, /Uptime/);
});

test("a forged cookie is not a session", () => {
  auth.reset();
  const res = responseForTest();
  routes.GET["/status"](
    { headers: { cookie: `status_session=${"a".repeat(64)}` }, query: {} },
    res,
  );
  assert.equal(res.statusCode, 401);
});

test("signing out invalidates the cookie it was holding", () => {
  auth.reset();
  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.3",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );
  const cookie = cookieFrom(login);

  routes.GET["/status/logout"]({ headers: { cookie } }, responseForTest());

  const res = responseForTest();
  routes.GET["/status"]({ headers: { cookie }, query: {} }, res);
  assert.equal(res.statusCode, 401);
});

test("guessing is capped per address", () => {
  auth.reset();
  const ip = "203.0.113.4";
  for (let attempt = 0; attempt < auth.ATTEMPT_LIMIT; attempt++) {
    const res = responseForTest();
    routes.POST["/status/login"](
      { ip, headers: {}, body: { password: "wrong" } },
      res,
    );
    assert.equal(res.statusCode, 401);
  }

  const blocked = responseForTest();
  routes.POST["/status/login"](
    { ip, headers: {}, body: { password: "wrong" } },
    blocked,
  );
  assert.equal(blocked.statusCode, 429);

  // Even the right password waits out the cooldown.
  const correct = responseForTest();
  routes.POST["/status/login"](
    { ip, headers: {}, body: { password: "correct-horse-battery" } },
    correct,
  );
  assert.equal(correct.statusCode, 429);

  // A different address is unaffected.
  const other = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.5",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    other,
  );
  assert.equal(other.statusCode, 303);
});

test("json carries the same numbers as the page", () => {
  auth.reset();
  metrics.reset();
  metrics.record("web", "run");
  metrics.record("web", "run");
  metrics.record("run", "web:lune");
  metrics.record("limited", "run");

  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.6",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );

  const res = responseForTest();
  routes.GET["/status"](
    { headers: { cookie: cookieFrom(login) }, query: { format: "json" } },
    res,
  );

  assert.equal(res.body.web.day.total, 2);
  assert.equal(res.body.web.day.byName.run, 2);
  assert.equal(res.body.runs.day.byName["web:lune"], 1);
  assert.equal(res.body.limited.day.total, 1);
  assert.ok(res.body.process.uptimeMs >= 0);
});

test("counts fall out of their window", () => {
  metrics.reset();
  const now = Date.now();
  metrics.record("web", "run");
  assert.equal(metrics.countBy("web", 60_000, now).total, 1);
  assert.equal(metrics.countBy("web", 60_000, now + 120_000).total, 0);
});

test("live sessions are counted by the surface that opened them", () => {
  const { closeSession, openSession } = require("../src/core/sessions");
  const { collect } = require("../src/http/routes/status");

  openSession("t-sse", { isWeb: true, mode: "sse" });
  openSession("t-poll", { isWeb: true, mode: "poll" });
  openSession("t-discord", { deliver() {} });

  const stats = collect();
  assert.equal(stats.sessions.total, 3);
  assert.equal(stats.sessions.web, 2);
  assert.equal(stats.sessions.webStream, 1);
  assert.equal(stats.sessions.webPoll, 1);
  assert.equal(stats.sessions.discord, 1);

  for (const token of ["t-sse", "t-poll", "t-discord"]) closeSession(token);
  assert.equal(collect().sessions.total, 0);
});

test("host load is reported once the sampler has two readings", () => {
  const { collect } = require("../src/http/routes/status");
  const { sampleLoad } = require("../src/metrics");

  sampleLoad(Date.now() + 1000);
  const stats = collect();

  assert.ok(stats.host.cores >= 1);
  assert.ok(stats.host.memoryUsedBytes > 0);
  assert.ok(stats.host.memoryUsedBytes <= stats.host.memoryTotalBytes);
  assert.ok(stats.host.cpuSystemPercent >= 0 && stats.host.cpuSystemPercent <= 100);
  assert.ok(stats.host.cpuProcessPercent >= 0);
});

test("the server list is rendered behind the login, never on /stats", () => {
  auth.reset();
  const { collect } = require("../src/http/routes/status");
  const stats = collect();

  // The bot client is not logged in under test, so the list degrades rather
  // than throwing.
  assert.ok(stats.discord === null || Array.isArray(stats.discord.guildList));

  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.20",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );
  const res = responseForTest();
  routes.GET["/status"]({ headers: { cookie: cookieFrom(login) }, query: {} }, res);
  assert.match(res.body, /Servers/);
});

test("only the signed-in page carries the refresh, not the login screen", () => {
  auth.reset();
  const locked = responseForTest();
  routes.GET["/status"]({ headers: {}, query: {} }, locked);
  assert.doesNotMatch(locked.body, /http-equiv="refresh"/);

  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.21",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );
  const res = responseForTest();
  routes.GET["/status"]({ headers: { cookie: cookieFrom(login) }, query: {} }, res);
  assert.match(res.body, /<meta http-equiv="refresh" content="1">/);
});

test("histogram buckets events by age", () => {
  metrics.reset();
  const now = Date.now();
  metrics.record("run", "web:lune");
  metrics.record("run", "web:lune");

  const series = metrics.histogram("run", 60_000, 10, now);
  assert.equal(series.length, 10);
  assert.equal(series.at(-1).count, 2, "just-recorded events land in the newest");
  assert.equal(series[0].count, 0);

  // Five minutes on, the same events sit five buckets back - in the bucket
  // that starts at the moment they were recorded.
  const later = metrics.histogram("run", 60_000, 10, now + 5 * 60_000);
  assert.equal(later.at(-1).count, 0);
  assert.equal(later[5].count, 2);

  // Past the window they fall out entirely.
  const gone = metrics.histogram("run", 60_000, 10, now + 60 * 60_000);
  assert.equal(
    gone.reduce((sum, point) => sum + point.count, 0),
    0,
  );
});

test("the page draws charts as inline svg with no script", () => {
  auth.reset();
  metrics.reset();
  metrics.record("run", "web:lune");

  const login = responseForTest();
  routes.POST["/status/login"](
    {
      ip: "203.0.113.30",
      headers: {},
      body: { password: "correct-horse-battery" },
    },
    login,
  );
  const res = responseForTest();
  routes.GET["/status"]({ headers: { cookie: cookieFrom(login) }, query: {} }, res);

  assert.match(res.body, /<svg viewBox="0 0 720 96"/);
  assert.match(res.body, /Runs per hour/);
  assert.match(res.body, /Web requests per hour/);
  // Native SVG tooltips stand in for a hover layer, since no JS may run here.
  assert.match(res.body, /<title>/);
  assert.doesNotMatch(res.body, /<script/);
});
