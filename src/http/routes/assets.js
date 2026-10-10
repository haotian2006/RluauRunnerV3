const { logBot } = require("../../log");
const { requireSecret } = require("../middleware");

const THUMBNAIL_SIZES = [30, 42, 50, 75, 110, 140, 150, 250, 420, 512, 700];
const DEFAULT_SIZE = 420;
const ID_PATTERN = /^\d{1,20}$/;
const RESOLVED_TTL_MS = 60 * 60 * 1000;
const FAILED_TTL_MS = 5 * 60 * 1000;
const MAX_CACHE_ENTRIES = 2000;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 10 * 1000;
const CDN_HOST = "tr.rbxcdn.com";
const MAX_BATCH = 100;
const MAX_RETRY_AFTER_MS = 5 * 1000;

// The unauthenticated thumbnails API allows one request per second per IP, so
// lookups are queued, batched by size, and paced.
const pacing = { batchDelayMs: 50, minIntervalMs: 1100, maxWaitMs: 20 * 1000 };

const resolved = new Map();
const queued = new Map(); // size -> Map(id -> { waiters, since })
let nextSlotAt = 0;
let draining = false;

function snapSize(requested) {
  const n = Number(requested);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_SIZE;
  return THUMBNAIL_SIZES.find((s) => s >= n) ?? THUMBNAIL_SIZES.at(-1);
}

function remember(key, entry, ttl) {
  if (resolved.size >= MAX_CACHE_ENTRIES) {
    resolved.delete(resolved.keys().next().value);
  }
  resolved.set(key, { ...entry, expires: Date.now() + ttl });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function settle(size, id, slot, entry) {
  const key = `${id}:${size}`;
  // Pending and rate-limited answers aren't cached, so the next call asks again.
  if (entry.state === "Completed") remember(key, entry, RESOLVED_TTL_MS);
  else if (entry.state !== "Pending" && entry.state !== "RateLimited") {
    remember(key, entry, FAILED_TTL_MS);
  }
  for (const w of slot.waiters) w.resolve(entry);
}

async function requestBatch(size, batch) {
  const ids = [...batch.keys()].join(",");
  const url = `https://thumbnails.roblox.com/v1/assets?assetIds=${ids}&size=${size}x${size}&format=Png`;
  const res = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
  if (res.status === 429) {
    const retryAfter = Number(res.headers.get("retry-after")) * 1000;
    nextSlotAt = Date.now() + Math.min(retryAfter || 1000, MAX_RETRY_AFTER_MS);
    for (const [id, slot] of batch) {
      if (Date.now() - slot.since > pacing.maxWaitMs) {
        settle(size, id, slot, { state: "RateLimited" });
        continue;
      }
      let sizeQueue = queued.get(size);
      if (!sizeQueue) queued.set(size, (sizeQueue = new Map()));
      const existing = sizeQueue.get(id);
      if (existing) existing.waiters.push(...slot.waiters);
      else sizeQueue.set(id, slot);
    }
    return;
  }
  if (!res.ok) throw new Error(`thumbnails API returned ${res.status}`);
  const items = new Map(((await res.json())?.data ?? []).map((d) => [String(d.targetId), d]));
  for (const [id, slot] of batch) {
    const item = items.get(id);
    settle(size, id, slot, item ? { state: item.state, url: item.imageUrl } : { state: "Error" });
  }
}

async function drain() {
  draining = true;
  try {
    await drainQueue();
  } finally {
    draining = false;
  }
}

async function drainQueue() {
  await sleep(pacing.batchDelayMs);
  while (queued.size > 0) {
    const wait = nextSlotAt - Date.now();
    if (wait > 0) await sleep(wait);
    const [size, sizeQueue] = queued.entries().next().value;
    const batch = new Map();
    for (const [id, slot] of sizeQueue) {
      if (batch.size >= MAX_BATCH) break;
      batch.set(id, slot);
      sizeQueue.delete(id);
    }
    if (sizeQueue.size === 0) queued.delete(size);
    nextSlotAt = Date.now() + pacing.minIntervalMs;
    try {
      await requestBatch(size, batch);
    } catch (err) {
      for (const slot of batch.values()) for (const w of slot.waiters) w.reject(err);
    }
  }
}

function resolveThumbnail(id, size) {
  const hit = resolved.get(`${id}:${size}`);
  if (hit && hit.expires > Date.now()) return Promise.resolve(hit);

  return new Promise((resolve, reject) => {
    let sizeQueue = queued.get(size);
    if (!sizeQueue) queued.set(size, (sizeQueue = new Map()));
    const slot = sizeQueue.get(id) ?? { waiters: [], since: Date.now() };
    slot.waiters.push({ resolve, reject });
    sizeQueue.set(id, slot);
    if (!draining) drain();
  });
}

async function downloadImage(url) {
  if (new URL(url).hostname !== CDN_HOST) throw new Error("unexpected image host");
  const res = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`CDN returned ${res.status}`);
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_IMAGE_BYTES) {
    throw new Error("image too large");
  }
  const bytes = Buffer.from(await res.arrayBuffer());
  if (bytes.length > MAX_IMAGE_BYTES) throw new Error("image too large");
  return bytes;
}

function registerAssetRoutes(app) {
  // Worker-only: the bot's IP would get throttled by Roblox if this were an open proxy.
  app.get("/asset/:id", requireSecret, async (req, res) => {
    const { id } = req.params;
    if (!ID_PATTERN.test(id)) {
      return res.status(400).json({ message: "Invalid asset id" });
    }
    const size = snapSize(req.query.size);

    let entry;
    try {
      entry = await resolveThumbnail(id, size);
    } catch (err) {
      logBot("Assets", `lookup ${id} failed: ${err.message}`);
      return res.status(502).json({ message: "Thumbnail lookup failed" });
    }

    if (entry.state === "Pending" || entry.state === "RateLimited") {
      return res.status(503).json({ state: entry.state, size });
    }
    if (entry.state !== "Completed") {
      return res.status(404).json({ state: entry.state, size });
    }
    if (req.query.raw === undefined) {
      return res.json({ state: entry.state, url: entry.url, size });
    }

    try {
      const bytes = await downloadImage(entry.url);
      res.setHeader("Content-Type", "image/png");
      res.send(bytes);
    } catch (err) {
      logBot("Assets", `download ${id} failed: ${err.message}`);
      res.status(502).json({ message: "Image download failed" });
    }
  });
}

module.exports = { registerAssetRoutes, snapSize, _resolved: resolved, _pacing: pacing };
