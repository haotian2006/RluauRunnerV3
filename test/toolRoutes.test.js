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

test("POST /bytecode overrides source directives for the playground", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: ip(),
      body: {
        code: "--!native\n--!optimize 0\nprint('hi')",
        options: { optimizeLevel: 2, debugLevel: 2, output: "vm" },
      },
    },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.options.optimizeLevel, 2);
  assert.equal(res.body.options.debugLevel, 2);
  assert.equal(res.body.options.native, false);
  assert.match(res.body.bytecode, /\s+3: print\('hi'\)/);
});

test("POST /bytecode selects ARM64 native output", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: ip(), body: { code: "print(1)", options: { output: "native-a64" } } },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.options.architecture, "a64");
  assert.match(res.body.bytecode, /bb_bytecode/);
});

test("POST /bytecode rejects unsupported options", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: ip(), body: { code: "print(1)", options: { output: "native-invalid" } } },
    res,
  );
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "Invalid bytecode output format");
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

test("a source past the tool size cap is rejected before it reaches the compiler", async () => {
  const res = responseForTest();
  // Over 1MB, well under the 100MB upload limit that other endpoints allow.
  const huge = "a".repeat(1024 * 1024 + 1);
  await routes.POST["/bytecode"](
    { method: "POST", ip: ip(), body: { code: huge } },
    res,
  );
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /too large/i);
});

test("the per-minute cap is 120 and each tool counts separately", async () => {
  const { TOOL_RATE_LIMIT } = require("../src/web/rateLimit");
  assert.equal(TOOL_RATE_LIMIT, 120);

  // A caller that never trips the debounce still stops at the per-minute cap.
  // Drive the limiter directly so the test does not spawn 120 compilers.
  const { checkToolRate } = require("../src/web/rateLimit");
  const key = "roblox-cap-test";
  let allowed = 0;
  for (let i = 0; i < TOOL_RATE_LIMIT + 5; i++) {
    if (checkToolRate(key, "bytecode")) allowed++;
  }
  assert.equal(allowed, TOOL_RATE_LIMIT);

  // ast keeps its own budget.
  assert.equal(checkToolRate(key, "ast"), true);
});

test("typeLevel bakes register type info into the listing", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: ip(),
      body: {
        code: "local function add(a: number, b: number): number\n\treturn a + b\nend\nprint(add(1,2))",
        options: { typeLevel: 1 },
      },
    },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.options.typeLevel, 1);
  // -t1 annotates registers with their inferred types; -t0 does not.
  assert.match(res.body.bytecode, /R0: number \[argument\]/);
});

test("typeLevel only goes up to 1", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    {
      method: "POST",
      ip: ip(),
      body: { code: "print(1)", options: { typeLevel: 2 } },
    },
    res,
  );
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /typeLevel must be between 0 and 1/);
});

test("the asm output returns native assembly for the requested target", async () => {
  for (const [output, arch] of [
    ["asm-x64", "x64"],
    ["asm-a64", "a64"],
  ]) {
    const res = responseForTest();
    await routes.POST["/bytecode"](
      {
        method: "POST",
        ip: ip(),
        body: { code: "local x = 1 + 2\nprint(x)", options: { output } },
      },
      res,
    );
    assert.equal(res.statusCode, 200, `${output} should compile`);
    assert.equal(res.body.options.asm, true);
    assert.equal(res.body.options.native, false, "asm is its own mode");
    assert.equal(res.body.options.architecture, arch);
    // codegenasm interleaves real instructions with the VM opcodes.
    assert.match(res.body.bytecode, /; function/);
  }
});

test("the --!asm directive selects the asm mode from the source", async () => {
  const res = responseForTest();
  await routes.POST["/bytecode"](
    { method: "POST", ip: ip(), body: { code: "--!asm\nprint(1)" } },
    res,
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.options.asm, true);
  assert.equal(res.body.options.binary, false, "a listing mode beats binary");
});

test("--!typeinfo is read from the source and clamped", () => {
  const { getByteCodeOptions } = require("../src/tools/bytecode");
  assert.equal(getByteCodeOptions("--!typeinfo 1\nprint(1)").typeLevel, 1);
  assert.equal(getByteCodeOptions("--!typeinfo 7\nprint(1)").typeLevel, 1);
  assert.equal(getByteCodeOptions("print(1)").typeLevel, 0);
});
