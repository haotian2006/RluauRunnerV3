// Roblox assets: downloads a public model through Open Cloud's Asset Delivery API
// (needs ROBLOX_ASSET_API_KEY with legacy-asset:manage) and builds it like a release .rbxm.
const zlib = require("zlib");

const { ROBLOX_ASSET_API_KEY } = require("../config");
const { ImportError, FETCH_TIMEOUT_MS } = require("./common");

const API = "https://apis.roblox.com/asset-delivery-api/v1/assetId";
const MAX_MODEL_BYTES = 20 * 1024 * 1024;
const ID = /^\d{1,20}$/;
const HOSTS = new Set(["roblox.com", "www.roblox.com", "create.roblox.com"]);

function asId(s) {
  return ID.test(s ?? "") ? { mode: "roblox", id: s } : null;
}

// 123, "rbxassetid://123", roblox.com/library/123/..., create.roblox.com/store/asset/123/...,
// roblox.com/asset/?id=123. Anything else is left to the other parsers.
function parseRobloxTarget(raw) {
  const text = String(raw).trim();
  if (ID.test(text)) return asId(text);
  const scheme = text.match(/^rbxassetid:\/\/(\d+)$/i);
  if (scheme) return asId(scheme[1]);
  let u;
  try {
    u = new URL(text);
  } catch {
    return null;
  }
  if (!HOSTS.has(u.hostname.toLowerCase())) return null;
  const segs = u.pathname.split("/").filter(Boolean);
  const at = (name) => segs.findIndex((s) => s.toLowerCase() === name);
  let id = null;
  if (at("library") >= 0) id = segs[at("library") + 1];
  else if (at("catalog") >= 0) id = segs[at("catalog") + 1];
  else if (at("store") >= 0 && segs[at("store") + 1]?.toLowerCase() === "asset") id = segs[at("store") + 2];
  else if (at("asset") >= 0) id = u.searchParams.get("id");
  const target = asId(id);
  if (!target) throw new ImportError("expected a roblox.com asset link with an asset id", 400);
  return target;
}

async function readLimited(res) {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_MODEL_BYTES) {
    throw new ImportError("asset is larger than 20MB", 413);
  }
  const chunks = [];
  let seen = 0;
  for await (const c of res.body) {
    seen += c.length;
    if (seen > MAX_MODEL_BYTES) throw new ImportError("asset is larger than 20MB", 413);
    chunks.push(c);
  }
  return Buffer.concat(chunks);
}

async function buildRoblox(target, runBuild) {
  if (!ROBLOX_ASSET_API_KEY) throw new ImportError("Roblox asset imports aren't set up on this bot", 503);
  const res = await fetch(`${API}/${target.id}`, {
    headers: { "x-api-key": ROBLOX_ASSET_API_KEY },
    redirect: "error", // a redirect would carry the key to another host
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (res.status === 404 || res.status === 403) {
    throw new ImportError(`asset ${target.id} not found (or it isn't public)`, 404);
  }
  if (res.status === 429) throw new ImportError("Roblox is rate limiting asset downloads, try again shortly", 503);
  if (!res.ok) throw new ImportError(`Roblox returned ${res.status}`, 502);
  const { location } = await res.json().catch(() => ({}));
  let cdn;
  try {
    cdn = new URL(location);
  } catch {
    throw new ImportError("Roblox returned no download link", 502);
  }
  if (cdn.protocol !== "https:" || !cdn.hostname.endsWith(".rbxcdn.com")) {
    throw new ImportError("asset download pointed off Roblox's CDN", 502);
  }
  const file = await fetch(cdn, {
    headers: { "Accept-Encoding": "gzip" },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!file.ok) throw new ImportError(`Roblox CDN returned ${file.status}`, 502);
  const landed = new URL(file.url || cdn); // where redirects ended up
  if (landed.protocol !== "https:" || !landed.hostname.endsWith(".rbxcdn.com")) {
    throw new ImportError("asset download pointed off Roblox's CDN", 502);
  }
  let bytes = await readLimited(file);
  // The CDN can hand back gzip that fetch didn't decode.
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
    try {
      bytes = zlib.gunzipSync(bytes, { maxOutputLength: MAX_MODEL_BYTES });
    } catch {
      throw new ImportError("asset download was corrupt or larger than 20MB", 502);
    }
  }
  // Binary (<roblox!) or XML (<roblox ...>) model; images, audio and meshes aren't.
  if (!/^<roblox[!\s>]/.test(bytes.toString("latin1", 0, 8))) {
    throw new ImportError(`asset ${target.id} isn't a model`, 422);
  }
  return runBuild({ mode: "model", name: `Asset${target.id}` }, new Map([["model", bytes]]));
}

module.exports = { parseRobloxTarget, buildRoblox };
