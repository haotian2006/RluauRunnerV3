const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  CALLBACK_URL,
  COMPILE_SOURCE_MAX_BYTES,
  COMPILE_SOURCE_TOTAL_BYTES,
  COMPILE_SOURCE_TTL_MS,
  PLAYGROUND_URL,
  STORE_COMPILE_SOURCE,
} = require("./config");
const { logBot } = require("./log");
const { generateUUID } = require("./util");

const STORE_DIR = path.join(os.tmpdir(), "rluau-sources");
const SWEEP_INTERVAL_MS = 1000 * 60 * 5;

/** id -> { id, token, filePath, bytes, expiresAt } */
const entries = new Map();
/** token -> id, so a live run can replace what it stored earlier. */
const tokenIndex = new Map();
// Ids whose file is gone because time or the byte budget took it, kept so a
// stale link can say "expired" rather than "never existed". Ids only.
const expiredIds = new Set();
const MAX_EXPIRED_IDS = 10000;
let totalBytes = 0;
let sweepTimer = null;

function enabled() {
  return STORE_COMPILE_SOURCE;
}

function rememberExpired(id) {
  if (expiredIds.size >= MAX_EXPIRED_IDS) {
    expiredIds.delete(expiredIds.values().next().value);
  }
  expiredIds.add(id);
}

function removeEntry(id, { expired = true } = {}) {
  const entry = entries.get(id);
  if (!entry) return;
  entries.delete(id);
  if (tokenIndex.get(entry.token) === id) tokenIndex.delete(entry.token);
  totalBytes -= entry.bytes;
  if (expired) rememberExpired(id);
  fs.promises.unlink(entry.filePath).catch(() => {});
}

function sweep() {
  const now = Date.now();
  for (const [id, entry] of entries) {
    if (entry.expiresAt <= now) removeEntry(id);
  }
}

// Map iteration is insertion-ordered, and every write appends, so the first
// live entry is always the oldest one.
function evictUntilUnderBudget() {
  for (const id of entries.keys()) {
    if (totalBytes <= COMPILE_SOURCE_TOTAL_BYTES) return;
    removeEntry(id);
  }
}

function ensureSweeping() {
  if (sweepTimer) return;
  sweepTimer = setInterval(sweep, SWEEP_INTERVAL_MS);
  sweepTimer.unref?.();
}

function sourceUrlFor(id) {
  return `${CALLBACK_URL}/source/${id}`;
}

function rawUrlFor(id) {
  return `${CALLBACK_URL}/raw/${id}`;
}

// Only the id travels. The playground already knows this host's address, so it
// builds the /raw URL itself and nothing here has to survive a domain change.
function playgroundUrlFor(id) {
  if (!PLAYGROUND_URL) return null;
  const separator = PLAYGROUND_URL.includes("?") ? "&" : "?";
  return `${PLAYGROUND_URL}${separator}source=${encodeURIComponent(id)}`;
}

/**
 * Persist the source a run is about to execute and return the link to show.
 * Returns null when the feature is off or the source is too big to be worth
 * reading in a browser. Called again for the same token (the local runtime
 * rewrites the source before running it) replaces the earlier copy.
 */
function storeSource(token, source) {
  if (!enabled() || typeof source !== "string" || !token) return null;

  const buffer = Buffer.from(source, "utf8");
  if (buffer.length === 0 || buffer.length > COMPILE_SOURCE_MAX_BYTES) {
    releaseToken(token);
    return null;
  }

  ensureSweeping();
  sweep();
  // The earlier copy is superseded, not expired: it is the same run.
  releaseToken(token, { expired: false });

  const id = generateUUID();
  const filePath = path.join(STORE_DIR, `${id}.luau`);
  try {
    fs.mkdirSync(STORE_DIR, { recursive: true });
    fs.writeFileSync(filePath, buffer);
  } catch (err) {
    logBot("Source Store", `failed to write ${id}: ${err.message}`);
    return null;
  }

  entries.set(id, {
    id,
    token,
    filePath,
    bytes: buffer.length,
    expiresAt: Date.now() + COMPILE_SOURCE_TTL_MS,
  });
  tokenIndex.set(token, id);
  totalBytes += buffer.length;
  evictUntilUnderBudget();

  return entries.has(id) ? sourceUrlFor(id) : null;
}

function releaseToken(token, { expired = true } = {}) {
  const existing = tokenIndex.get(token);
  if (existing) removeEntry(existing, { expired });
}

/** The link for a run already in flight, for embeds rebuilt after the store. */
function getSourceUrl(token) {
  if (!enabled() || !token) return null;
  const id = tokenIndex.get(token);
  if (!id) return null;
  const entry = entries.get(id);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    removeEntry(id);
    return null;
  }
  return sourceUrlFor(id);
}

/** True when this id held a source that time or the byte budget removed. */
function wasExpired(id) {
  return expiredIds.has(id);
}

/** The stored file, or null when it never existed or has expired. */
function getSource(id) {
  const entry = entries.get(id);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    removeEntry(id);
    return null;
  }
  return entry;
}

module.exports = {
  STORE_DIR,
  enabled,
  getSource,
  getSourceUrl,
  playgroundUrlFor,
  rawUrlFor,
  releaseToken,
  storeSource,
  wasExpired,
};
