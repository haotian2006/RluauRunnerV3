const fs = require("fs");
const os = require("os");
const path = require("path");
const zstd = require("zstd-napi");

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
const SOURCE_EXT = ".luau.zst";
// Sources written before the store packed them. Nothing writes this shape any
// more, and readSource cannot make sense of one, so any that survive a restart
// are unreadable by definition.
const LEGACY_EXT = ".luau";
const COMPRESSION_LEVEL = 10;

/** id -> { id, token, filePath, bytes, rawBytes, expiresAt } */
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

/**
 * Drop files on disk that no live entry points at. Entries live in memory only,
 * so a restart orphans every file it left behind; the periodic sweep can only
 * see what this process stored. Age decides, because another process may be
 * sharing the directory and its recent files are still somebody's link. Files
 * in the pre-packed format go regardless: no version still serves them.
 * @returns {{ removed: number, bytes: number }}
 */
function purgeStaleFiles(now = Date.now()) {
  const result = { removed: 0, bytes: 0 };
  let names;
  try {
    names = fs.readdirSync(STORE_DIR);
  } catch {
    return result;
  }

  const live = new Set();
  for (const entry of entries.values()) live.add(entry.filePath);

  for (const name of names) {
    const filePath = path.join(STORE_DIR, name);
    if (live.has(filePath)) continue;

    let stat;
    try {
      stat = fs.statSync(filePath);
    } catch {
      continue;
    }
    if (!stat.isFile()) continue;

    const legacy = name.endsWith(LEGACY_EXT) && !name.endsWith(SOURCE_EXT);
    if (!legacy && now - stat.mtimeMs <= COMPILE_SOURCE_TTL_MS) continue;

    try {
      fs.unlinkSync(filePath);
      result.removed += 1;
      result.bytes += stat.size;
    } catch {}
  }

  if (result.removed) {
    logBot(
      "Source Store",
      `purged ${result.removed} stale file(s), ${result.bytes} bytes`,
    );
  }
  return result;
}

function ensureSweeping() {
  if (sweepTimer) return;
  purgeStaleFiles();
  sweepTimer = setInterval(() => {
    sweep();
    purgeStaleFiles();
  }, SWEEP_INTERVAL_MS);
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
  // The cap is on the source the user wrote, not on how well it happens to
  // compress, so it is checked before the source is packed.
  if (buffer.length === 0 || buffer.length > COMPILE_SOURCE_MAX_BYTES) {
    releaseToken(token);
    return null;
  }

  let packed;
  try {
    packed = zstd.compress(buffer, COMPRESSION_LEVEL);
  } catch (err) {
    logBot("Source Store", `failed to compress: ${err.message}`);
    return null;
  }

  ensureSweeping();
  sweep();
  // The earlier copy is superseded, not expired: it is the same run.
  releaseToken(token, { expired: false });

  const id = generateUUID();
  const filePath = path.join(STORE_DIR, `${id}${SOURCE_EXT}`);
  try {
    fs.mkdirSync(STORE_DIR, { recursive: true });
    fs.writeFileSync(filePath, packed);
  } catch (err) {
    logBot("Source Store", `failed to write ${id}: ${err.message}`);
    return null;
  }

  entries.set(id, {
    id,
    token,
    filePath,
    // The budget guards the disk, so it counts what the disk actually holds.
    bytes: packed.length,
    rawBytes: buffer.length,
    expiresAt: Date.now() + COMPILE_SOURCE_TTL_MS,
  });
  tokenIndex.set(token, id);
  totalBytes += packed.length;
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

/**
 * The source behind an entry, unpacked. Callers never see the stored form.
 * @param {{ filePath: string }} entry
 * @returns {Promise<Buffer>}
 */
async function readSource(entry) {
  return zstd.decompress(await fs.promises.readFile(entry.filePath));
}

/** What the store is holding, for the status page. */
function storeStats() {
  return {
    entries: entries.size,
    bytes: totalBytes,
    budgetBytes: COMPILE_SOURCE_TOTAL_BYTES,
  };
}

module.exports = {
  STORE_DIR,
  enabled,
  storeStats,
  getSource,
  purgeStaleFiles,
  readSource,
  getSourceUrl,
  playgroundUrlFor,
  rawUrlFor,
  releaseToken,
  storeSource,
  wasExpired,
};
