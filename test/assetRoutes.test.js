const test = require("node:test");
const assert = require("node:assert/strict");

const { SECRET_TOKEN } = require("../src/state");
const { registerAssetRoutes, snapSize, _resolved, _pacing } = require("../src/http/routes/assets");

_pacing.batchDelayMs = 5;
_pacing.minIntervalMs = 0;

function routeForTest() {
  let handlers;
  registerAssetRoutes({
    get(path, ...hs) {
      if (path === "/asset/:id") handlers = hs;
    },
  });
  return async (req) => {
    const res = {
      statusCode: 200,
      body: null,
      headers: {},
      status(code) {
        this.statusCode = code;
        return this;
      },
      json(body) {
        this.body = body;
        return this;
      },
      send(body) {
        this.body = body;
        return this;
      },
      setHeader(k, v) {
        this.headers[k] = v;
      },
    };
    req.headers ??= { "x-secret-token": SECRET_TOKEN };
    req.query ??= {};
    let pending;
    handlers[0](req, res, () => {
      pending = handlers[1](req, res);
    });
    await pending;
    return res;
  };
}

function stubFetch(t, routes) {
  const calls = [];
  const original = global.fetch;
  global.fetch = async (url) => {
    calls.push(url);
    for (const [match, reply] of routes) {
      if (url.includes(match)) return reply(url);
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  t.after(() => {
    global.fetch = original;
    _resolved.clear();
  });
  return calls;
}

const json = (body, status = 200) => new Response(JSON.stringify(body), { status });

test("snapSize rounds up to a valid thumbnail size", () => {
  assert.equal(snapSize(undefined), 420);
  assert.equal(snapSize("100"), 110);
  assert.equal(snapSize(420), 420);
  assert.equal(snapSize(5000), 700);
  assert.equal(snapSize("abc"), 420);
});

test("rejects callers without the worker secret", async () => {
  const route = routeForTest();
  const res = await route({ params: { id: "1" }, headers: {} });
  assert.equal(res.statusCode, 403);
});

test("rejects non-numeric ids", async () => {
  const route = routeForTest();
  const res = await route({ params: { id: "1;drop" } });
  assert.equal(res.statusCode, 400);
});

test("resolves a thumbnail url and caches it", async (t) => {
  const calls = stubFetch(t, [
    [
      "thumbnails.roblox.com",
      () => json({ data: [{ targetId: 123, state: "Completed", imageUrl: "https://tr.rbxcdn.com/x/150/150/Image/Png/noFilter" }] }),
    ],
  ]);
  const route = routeForTest();
  const first = await route({ params: { id: "123" }, query: { size: "150" } });
  const second = await route({ params: { id: "123" }, query: { size: "150" } });
  assert.deepEqual(first.body, { state: "Completed", url: "https://tr.rbxcdn.com/x/150/150/Image/Png/noFilter", size: 150 });
  assert.deepEqual(second.body, first.body);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /assetIds=123&size=150x150&format=Png/);
});

test("raw mode proxies the png bytes", async (t) => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  stubFetch(t, [
    ["thumbnails.roblox.com", () => json({ data: [{ targetId: 5, state: "Completed", imageUrl: "https://tr.rbxcdn.com/y" }] })],
    ["tr.rbxcdn.com", () => new Response(png)],
  ]);
  const route = routeForTest();
  const res = await route({ params: { id: "5" }, query: { raw: "1" } });
  assert.equal(res.headers["Content-Type"], "image/png");
  assert.deepEqual(res.body, png);
});

test("raw mode refuses image urls off the Roblox CDN", async (t) => {
  stubFetch(t, [
    ["thumbnails.roblox.com", () => json({ data: [{ targetId: 6, state: "Completed", imageUrl: "http://127.0.0.1/secret" }] })],
  ]);
  const route = routeForTest();
  const res = await route({ params: { id: "6" }, query: { raw: "1" } });
  assert.equal(res.statusCode, 502);
});

test("pending thumbnails are retried, failed ones are cached", async (t) => {
  let state = "Pending";
  const calls = stubFetch(t, [
    ["assetIds=7&", () => json({ data: [{ targetId: 7, state, imageUrl: "https://tr.rbxcdn.com/p" }] })],
    ["assetIds=8&", () => json({ data: [{ targetId: 8, state: "Blocked", imageUrl: "https://tr.rbxcdn.com/b" }] })],
  ]);
  const route = routeForTest();
  assert.equal((await route({ params: { id: "7" } })).statusCode, 503);
  state = "Completed";
  assert.equal((await route({ params: { id: "7" } })).statusCode, 200);

  assert.equal((await route({ params: { id: "8" } })).statusCode, 404);
  assert.equal((await route({ params: { id: "8" } })).statusCode, 404);
  assert.equal(calls.filter((u) => u.includes("assetIds=8&")).length, 1);
});

test("concurrent lookups of one size share a single API call", async (t) => {
  const calls = stubFetch(t, [
    [
      "thumbnails.roblox.com",
      () =>
        json({
          data: [
            { targetId: 11, state: "Completed", imageUrl: "https://tr.rbxcdn.com/a" },
            { targetId: 12, state: "Completed", imageUrl: "https://tr.rbxcdn.com/b" },
          ],
        }),
    ],
  ]);
  const route = routeForTest();
  const [a, b, c] = await Promise.all([
    route({ params: { id: "11" } }),
    route({ params: { id: "12" } }),
    route({ params: { id: "11" } }),
  ]);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /assetIds=11,12&/);
  assert.equal(a.body.url, "https://tr.rbxcdn.com/a");
  assert.equal(b.body.url, "https://tr.rbxcdn.com/b");
  assert.equal(c.body.url, "https://tr.rbxcdn.com/a");
});

test("a rate-limited batch is retried after retry-after", async (t) => {
  let attempts = 0;
  stubFetch(t, [
    [
      "assetIds=21&",
      () =>
        ++attempts === 1
          ? new Response("", { status: 429, headers: { "retry-after": "0.02" } })
          : json({ data: [{ targetId: 21, state: "Completed", imageUrl: "https://tr.rbxcdn.com/r" }] }),
    ],
  ]);
  const route = routeForTest();
  const res = await route({ params: { id: "21" } });
  assert.equal(attempts, 2);
  assert.equal(res.statusCode, 200);
});

test("gives up with 503 once the wait budget is spent", async (t) => {
  const saved = _pacing.maxWaitMs;
  _pacing.maxWaitMs = 0;
  t.after(() => (_pacing.maxWaitMs = saved));
  stubFetch(t, [
    ["assetIds=31&", () => new Response("", { status: 429, headers: { "retry-after": "0.01" } })],
  ]);
  const route = routeForTest();
  const res = await route({ params: { id: "31" } });
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.state, "RateLimited");
});
