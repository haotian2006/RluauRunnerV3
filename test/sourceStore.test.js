process.env.STORE_COMPILE_SOURCE = "true";
process.env.COMPILE_SOURCE_MAX_BYTES = "64";
process.env.COMPILE_SOURCE_TOTAL_BYTES = "100";

const fs = require("fs");
const { PassThrough } = require("stream");
const test = require("node:test");
const assert = require("node:assert/strict");

const { CALLBACK_URL } = require("../src/config");
const { PLAYGROUND_URL } = require("../src/config");
const {
  getSource,
  playgroundUrlFor,
  getSourceUrl,
  releaseToken,
  storeSource,
} = require("../src/sourceStore");
const { registerSourceRoutes } = require("../src/http/routes/source");

function idFromUrl(url) {
  return url.slice(url.lastIndexOf("/") + 1);
}

function routesForTest() {
  const routes = {};
  const app = {
    get(path, ...handlers) {
      routes[path] = handlers.at(-1);
    },
    post() {},
  };
  registerSourceRoutes(app);
  return routes;
}

// A stream, because the raw route pipes the file straight into it.
function responseForTest() {
  return Object.assign(new PassThrough(), {
    statusCode: 200,
    headers: {},
    body: null,
    redirectedTo: null,
    headersSent: false,
    setHeader(name, value) {
      this.headers[name] = value;
    },
    removeHeader(name) {
      delete this.headers[name];
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    type(value) {
      this.headers["Content-Type"] = value;
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
  });
}

test("a stored source is reachable by its token and its id", () => {
  const url = storeSource("token-a", "print('hi')");
  assert.ok(url.startsWith(`${CALLBACK_URL}/source/`));
  assert.equal(getSourceUrl("token-a"), url);

  const entry = getSource(idFromUrl(url));
  assert.equal(fs.readFileSync(entry.filePath, "utf8"), "print('hi')");
  releaseToken("token-a");
});

test("storing again for the same token drops the earlier copy", () => {
  const first = storeSource("token-b", "print('one')");
  const second = storeSource("token-b", "print('two')");

  assert.notEqual(first, second);
  assert.equal(getSource(idFromUrl(first)), null);
  assert.ok(getSource(idFromUrl(second)));
  assert.equal(getSourceUrl("token-b"), second);
  releaseToken("token-b");
});

test("a source over the per-entry cap is not stored at all", () => {
  assert.equal(storeSource("token-c", "x".repeat(65)), null);
  assert.equal(getSourceUrl("token-c"), null);
});

test("an oversized rerun clears the link the first run left behind", () => {
  storeSource("token-d", "print('small')");
  assert.equal(storeSource("token-d", "x".repeat(65)), null);
  assert.equal(getSourceUrl("token-d"), null);
});

test("the oldest sources are evicted once the total budget is passed", () => {
  const oldest = storeSource("token-e", "a".repeat(60));
  const newer = storeSource("token-f", "b".repeat(60));

  assert.equal(getSource(idFromUrl(oldest)), null);
  assert.ok(getSource(idFromUrl(newer)));
  releaseToken("token-f");
});

test("an expired source is gone from both indexes", () => {
  const url = storeSource("token-g", "print('bye')");
  const entry = getSource(idFromUrl(url));
  entry.expiresAt = Date.now() - 1;

  assert.equal(getSource(idFromUrl(url)), null);
  assert.equal(getSourceUrl("token-g"), null);
});

test("the raw route serves the stored text as plain text", async () => {
  const url = storeSource("token-h", "print('raw')");
  const id = idFromUrl(url);
  const res = responseForTest();
  res.setHeader("Access-Control-Allow-Origin", "*");

  routesForTest()["/raw/:id"]({ params: { id } }, res);

  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);
  assert.equal(Buffer.concat(chunks).toString("utf8"), "print('raw')");
  assert.equal(res.headers["Content-Type"], "text/plain; charset=utf-8");
  assert.equal(res.headers["X-Content-Type-Options"], "nosniff");
  // The playground is on another origin and has to fetch this.
  assert.equal(res.headers["Access-Control-Allow-Origin"], "*");
  releaseToken("token-h");
});

test("an id that was never stored answers with runnable Luau", () => {
  const res = responseForTest();
  routesForTest()["/raw/:id"]({ params: { id: "aaaaaaaa-0000" } }, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body, `error("DOES NOT EXIST")`);
  assert.equal(res.headers["X-Source-Status"], "unknown");
});

test("an id whose source expired says so instead of denying it existed", () => {
  const url = storeSource("token-j", "print('gone')");
  const id = idFromUrl(url);
  getSource(id).expiresAt = Date.now() - 1;
  getSource(id);

  const res = responseForTest();
  routesForTest()["/raw/:id"]({ params: { id } }, res);
  assert.equal(res.body, `error("EXPIRED")`);
  assert.equal(res.headers["X-Source-Status"], "expired");
});

test("a path that is not an id shape never reaches the store", () => {
  const res = responseForTest();
  routesForTest()["/raw/:id"]({ params: { id: "../../etc/passwd" } }, res);
  assert.equal(res.body, `error("DOES NOT EXIST")`);
});

test("the source route does not leak the id to other origins", () => {
  const url = storeSource("token-i", "print('cors')");
  const res = responseForTest();
  res.setHeader("Access-Control-Allow-Origin", "*");

  routesForTest()["/source/:id"]({ params: { id: idFromUrl(url) } }, res);
  assert.equal(res.headers["Access-Control-Allow-Origin"], undefined);
  assert.equal(res.headers["Referrer-Policy"], "no-referrer");
  releaseToken("token-i");
});

test("the playground link carries only the id, not this host address", () => {
  const link = playgroundUrlFor("abc-123");
  if (!PLAYGROUND_URL) {
    assert.equal(link, null);
    return;
  }
  assert.ok(link.endsWith("source=abc-123"));
  assert.ok(!link.includes(CALLBACK_URL));
});
