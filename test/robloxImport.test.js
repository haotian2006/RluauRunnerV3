process.env.ROBLOX_ASSET_API_KEY = "test-key";

const test = require("node:test");
const assert = require("node:assert/strict");
const zlib = require("zlib");

const { parseRobloxTarget, buildRoblox } = require("../src/github/roblox");
const { parseTarget, ImportError } = require("../src/github/import");

const MODEL = Buffer.concat([Buffer.from("<roblox!\x89\xff\r\n\x1a\n", "latin1"), Buffer.alloc(16)]);

test("parses asset ids and Roblox links", () => {
  for (const raw of [
    "104116977416770",
    " 104116977416770 ",
    "rbxassetid://104116977416770",
    "https://www.roblox.com/library/104116977416770/Packet",
    "https://create.roblox.com/store/asset/104116977416770/Packet",
    "https://www.roblox.com/asset/?id=104116977416770",
  ]) {
    assert.deepEqual(parseRobloxTarget(raw), { mode: "roblox", id: "104116977416770" }, raw);
  }
  assert.equal(parseRobloxTarget("https://github.com/o/r"), null);
  assert.equal(parseRobloxTarget("wally:a/b"), null);
  assert.throws(() => parseRobloxTarget("https://www.roblox.com/games/123x"), ImportError);
});

test("import targets route ids to Roblox and leave GitHub and Wally alone", () => {
  assert.equal(parseTarget("123").mode, "roblox");
  assert.equal(parseTarget("wally:sleitnick/signal").mode, "wally");
  assert.equal(parseTarget("https://github.com/o/r").mode, "repo");
});

function stubFetch(t, routes) {
  const calls = [];
  t.mock.method(global, "fetch", async (url, init) => {
    const href = String(url);
    calls.push({ href, init });
    const make = routes.find(([prefix]) => href.startsWith(prefix))?.[1];
    if (!make) throw new Error(`unexpected fetch ${href}`);
    return make();
  });
  return calls;
}

const located = (location) => () => new Response(JSON.stringify({ location }), { status: 200 });

test("downloads through Open Cloud, follows the CDN link and unpacks gzip", async (t) => {
  const calls = stubFetch(t, [
    ["https://apis.roblox.com/", located("https://sc1.rbxcdn.com/abc")],
    ["https://sc1.rbxcdn.com/", () => new Response(zlib.gzipSync(MODEL))],
  ]);
  let seen;
  const out = await buildRoblox({ mode: "roblox", id: "42" }, async (config, files) => {
    seen = { config, model: files.get("model") };
    return Buffer.from("built");
  });
  assert.equal(out.toString(), "built");
  assert.deepEqual(seen.config, { mode: "model", name: "Asset42" });
  assert.deepEqual(seen.model, MODEL);
  assert.equal(calls[0].href, "https://apis.roblox.com/asset-delivery-api/v1/assetId/42");
  assert.equal(calls[0].init.headers["x-api-key"], "test-key");
});

test("rejects CDN links off Roblox, non-models and missing assets", async (t) => {
  const never = async () => assert.fail("should not build");
  stubFetch(t, [["https://apis.roblox.com/", located("https://evil.example/abc")]]);
  await assert.rejects(buildRoblox({ id: "1" }, never), /off Roblox's CDN/);

  t.mock.restoreAll();
  stubFetch(t, [
    ["https://apis.roblox.com/", located("https://sc1.rbxcdn.com/png")],
    ["https://sc1.rbxcdn.com/", () => new Response(Buffer.from("\x89PNG\r\n\x1a\n", "latin1"))],
  ]);
  await assert.rejects(buildRoblox({ id: "2" }, never), /isn't a model/);

  t.mock.restoreAll();
  stubFetch(t, [["https://apis.roblox.com/", () => new Response("{}", { status: 404 })]]);
  await assert.rejects(buildRoblox({ id: "3" }, never), (err) => err.status === 404);
});
