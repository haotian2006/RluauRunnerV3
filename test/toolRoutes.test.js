const test = require("node:test");
const assert = require("node:assert/strict");

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
    headers: {},
    contentType: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    type(value) {
      this.contentType = value;
      return this;
    },
    setHeader(name, value) {
      this.headers[name] = value;
    },
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

let nextIp = 0;
function ip() {
  nextIp += 1;
  return `10.0.0.${nextIp}`;
}

const routes = routesForTest();

test("POST /bytecode returns the compiler output and the options used", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: ip(), body: { code: "print('hi')" } },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.ok(res.body.bytecode.includes("GETIMPORT"));
  assert.equal(res.body.options.optimizeLevel, 2);
});

test("GET /bytecode returns plain text", async () => {
  const res = responseForTest();
  await routes.GET["/bytecode"](
    { method: "GET", ip: ip(), query: { code: "print('hi')" } },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.contentType, "text/plain; charset=utf-8");
  assert.ok(res.body.includes("GETIMPORT"));
});

test("POST /ast returns the parsed tree", async () => {
  const res = responseForTest();
  await routes.POST["/ast"](
    { method: "POST", ip: ip(), body: { code: "local x = 1" } },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.ok(JSON.parse(res.body.ast));
});

test("a syntax error answers 400 with the tool's own message", async () => {
  const res = responseForTest();
  await routes.POST["/ast"](
    { method: "POST", ip: ip(), body: { code: "local = = " } },
    res,
  );
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /Expected identifier/);
});

test("missing code is rejected", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"]({ method: "POST", ip: ip(), body: {} }, res);
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "Missing code");
});

test("back-to-back calls from one ip are debounced per tool", async () => {
  const caller = ip();
  const first = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: caller, body: { code: "print(1)" } },
    first,
  );
  assert.equal(first.statusCode, 200);

  const second = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: caller, body: { code: "print(1)" } },
    second,
  );
  assert.equal(second.statusCode, 429);

  // A different tool keeps its own budget.
  const other = responseForTest();
  await routes.POST["/ast"](
    { method: "POST", ip: caller, body: { code: "print(1)" } },
    other,
  );
  assert.equal(other.statusCode, 200);
});
