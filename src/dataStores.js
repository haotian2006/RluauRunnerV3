const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const {
  DATASTORE_DIR,
  DATASTORE_EXPIRY_MS,
  DATASTORE_GRANT_TTL_MS,
  DATASTORE_QUOTA_BYTES,
} = require("./config");
const { logBot } = require("./log");

// Persistent DataStore and MemoryStore records for sandboxed runs (Sandbox.luau), one file per
// Discord user on the bot host, so they outlive worker sessions and work from any worker. A worker
// reaches them only with a private token the bot mints per run and hands to LuauBot (never to run
// code); the token names the user, so a run reaches its own user's data and nothing else.
// Records are { v: JSON value, ...fields } under a store id ("d\0name\0scope", "h\0name", ...) and
// a key; MemoryStore records carry expiresAt and are dropped once it passes.

const SWEEP_INTERVAL_MS = 1000 * 60 * 60 * 6;
const MAX_STORE_BYTES = 120; // "d\0" + name (50) + "\0" + scope (50)
const MAX_KEY_BYTES = 50;
const MAX_METADATA_BYTES = 300;
const MAX_SORT_KEY_BYTES = 200;
const MAX_VERSION_BYTES = 32;
const MAX_USER_IDS = 4;
const MAX_CHANGES = 1000;
const NUMBER_FIELDS = ["created", "updated", "expiresAt", "priority", "order", "hiddenUntil"];

/** token -> { userId, expiresAt } */
const grants = new Map();
/** userId -> tail of that user's queued file operations */
const queues = new Map();
let sweepTimer = null;

function fileFor(userId) {
  return path.join(DATASTORE_DIR, `${userId}.json`);
}

function bytes(value) {
  return value == null ? 0 : Buffer.byteLength(value);
}

// Counted alike in Sandbox.luau, so a write the run saw succeed fits here too.
function entryBytes(store, key, entry) {
  return (
    bytes(store) + bytes(key) + bytes(entry.v) + bytes(entry.metadata) + bytes(entry.sortKey)
  );
}

function usedBytes(entries) {
  let used = 0;
  for (const [store, keys] of Object.entries(entries)) {
    for (const [key, entry] of Object.entries(keys)) {
      used += entryBytes(store, key, entry);
    }
  }
  return used;
}

function dropExpired(entries, now = Date.now()) {
  for (const [store, keys] of Object.entries(entries)) {
    for (const [key, entry] of Object.entries(keys)) {
      if (entry.expiresAt != null && entry.expiresAt <= now) delete keys[key];
    }
    if (Object.keys(keys).length === 0) delete entries[store];
  }
  return entries;
}

/**
 * Gives a sandboxed Discord run its private storage token, once; the worker payload carries it.
 * Web runs (no lasting user) and --!nosandbox runs (real DataStoreService) get none.
 */
function grantStorage(task, now = Date.now()) {
  if (!task || task.isWeb || task.nosandbox || !/^\d+$/.test(String(task.userId))) {
    return null;
  }
  const existing = task.storageToken && grants.get(task.storageToken);
  if (existing) {
    existing.expiresAt = now + DATASTORE_GRANT_TTL_MS;
    return task.storageToken;
  }
  const token = crypto.randomBytes(24).toString("base64url");
  grants.set(token, {
    userId: String(task.userId),
    expiresAt: now + DATASTORE_GRANT_TTL_MS,
  });
  task.storageToken = token;
  return token;
}

/** The user a token was minted for, renewing it; null if unknown or expired. */
function userForToken(token, now = Date.now()) {
  const grant = typeof token === "string" ? grants.get(token) : null;
  if (!grant) return null;
  if (grant.expiresAt <= now) {
    grants.delete(token);
    return null;
  }
  grant.expiresAt = now + DATASTORE_GRANT_TTL_MS;
  return grant.userId;
}

function queued(userId, operation) {
  const run = (queues.get(userId) || Promise.resolve()).then(operation, operation);
  const tail = run.catch(() => {});
  queues.set(userId, tail);
  tail.then(() => {
    if (queues.get(userId) === tail) queues.delete(userId);
  });
  return run;
}

async function readEntries(userId) {
  try {
    const parsed = JSON.parse(await fs.promises.readFile(fileFor(userId), "utf8"));
    return parsed && typeof parsed.entries === "object" && parsed.entries
      ? parsed.entries
      : {};
  } catch (err) {
    if (err.code !== "ENOENT") {
      logBot("DataStores", `unreadable data for ${userId}: ${err.message}`);
    }
    return {};
  }
}

async function writeEntries(userId, entries) {
  await fs.promises.mkdir(DATASTORE_DIR, { recursive: true, mode: 0o700 });
  const file = fileFor(userId);
  if (Object.keys(entries).length === 0) {
    await fs.promises.rm(file, { force: true });
    return;
  }
  const temp = `${file}.${process.pid}.tmp`;
  await fs.promises.writeFile(temp, JSON.stringify({ entries }), { mode: 0o600 });
  await fs.promises.rename(temp, file);
}

/** The user's data, and how much of the quota it uses; reading counts as use for expiry. */
function loadUserData(userId) {
  return queued(userId, async () => {
    const entries = dropExpired(await readEntries(userId));
    const now = new Date();
    await fs.promises.utimes(fileFor(userId), now, now).catch(() => {});
    return { entries, used: usedBytes(entries), quota: DATASTORE_QUOTA_BYTES };
  });
}

function optionalString(value, max) {
  return value == null || (typeof value === "string" && bytes(value) <= max);
}

/** The entry with only known fields, or null if any is malformed. */
function cleanEntry(entry) {
  if (!entry || typeof entry !== "object" || typeof entry.v !== "string") return null;
  if (
    !optionalString(entry.version, MAX_VERSION_BYTES) ||
    !optionalString(entry.metadata, MAX_METADATA_BYTES) ||
    !optionalString(entry.sortKey, MAX_SORT_KEY_BYTES)
  ) {
    return null;
  }
  if (
    entry.userIds != null &&
    (!Array.isArray(entry.userIds) ||
      entry.userIds.length > MAX_USER_IDS ||
      !entry.userIds.every((id) => Number.isFinite(id)))
  ) {
    return null;
  }
  const clean = { v: entry.v };
  for (const field of ["version", "metadata", "sortKey", "userIds"]) {
    if (entry[field] != null) clean[field] = entry[field];
  }
  for (const field of NUMBER_FIELDS) {
    if (entry[field] == null) continue;
    if (!Number.isFinite(entry[field])) return null;
    clean[field] = entry[field];
  }
  return clean;
}

/**
 * Applies a run's changes ([{ store, key, entry | null }]) key by key, so runs of one user on two
 * workers only race on the same key. Over quota, nothing is applied.
 */
function saveUserData(userId, changes) {
  if (!Array.isArray(changes) || changes.length > MAX_CHANGES) {
    return Promise.resolve({ status: 400, message: "changes must be an array of at most 1000" });
  }
  const cleaned = [];
  for (const change of changes) {
    const entry = change?.entry == null ? null : cleanEntry(change.entry);
    if (
      !change ||
      typeof change.store !== "string" ||
      typeof change.key !== "string" ||
      change.store.length === 0 ||
      change.key.length === 0 ||
      bytes(change.store) > MAX_STORE_BYTES ||
      bytes(change.key) > MAX_KEY_BYTES ||
      (change.entry != null && !entry)
    ) {
      return Promise.resolve({ status: 400, message: "malformed change" });
    }
    cleaned.push({ store: change.store, key: change.key, entry });
  }
  return queued(userId, async () => {
    const entries = await readEntries(userId);
    for (const { store, key, entry } of cleaned) {
      const keys = entries[store] || (entries[store] = {});
      if (entry) keys[key] = entry;
      else delete keys[key];
      if (Object.keys(keys).length === 0) delete entries[store];
    }
    dropExpired(entries);
    const used = usedBytes(entries);
    if (used > DATASTORE_QUOTA_BYTES) {
      return {
        status: 413,
        message: `DataStores for this user would hold ${Math.ceil(used / 1024)} KB, over the ${Math.floor(DATASTORE_QUOTA_BYTES / 1024)} KB limit.`,
      };
    }
    await writeEntries(userId, entries);
    return { status: 200, used, quota: DATASTORE_QUOTA_BYTES };
  });
}

/** Deletes data unused for DATASTORE_EXPIRY_MS, and expired grants. */
async function sweepDataStores(now = Date.now()) {
  for (const [token, grant] of grants) {
    if (grant.expiresAt <= now) grants.delete(token);
  }
  let names;
  try {
    names = await fs.promises.readdir(DATASTORE_DIR);
  } catch {
    return 0;
  }
  let removed = 0;
  for (const name of names) {
    const match = /^(\d+)\.json$/.exec(name);
    if (!match) continue;
    await queued(match[1], async () => {
      const file = path.join(DATASTORE_DIR, name);
      const stat = await fs.promises.stat(file).catch(() => null);
      if (stat && now - stat.mtimeMs > DATASTORE_EXPIRY_MS) {
        await fs.promises.rm(file, { force: true });
        removed += 1;
      }
    });
  }
  if (removed) logBot("DataStores", `removed ${removed} unused for ${Math.round(DATASTORE_EXPIRY_MS / 86400000)} days`);
  return removed;
}

function startDataStoreSweeps() {
  if (sweepTimer) return;
  sweepDataStores().catch(() => {});
  sweepTimer = setInterval(() => sweepDataStores().catch(() => {}), SWEEP_INTERVAL_MS);
  sweepTimer.unref?.();
}

// The status page polls every second, so the directory is read at most every 30 s.
const STATS_TTL_MS = 30 * 1000;
let statsCache = null;

function dataStoreStats(now = Date.now()) {
  if (statsCache && now - statsCache.at < STATS_TTL_MS) return statsCache.stats;
  let users = 0;
  let bytesOnDisk = 0;
  let names = [];
  try {
    names = fs.readdirSync(DATASTORE_DIR);
  } catch {}
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      bytesOnDisk += fs.statSync(path.join(DATASTORE_DIR, name)).size;
      users += 1;
    } catch {}
  }
  const liveGrants = [...grants.values()].filter((grant) => grant.expiresAt > now).length;
  const stats = {
    users,
    bytesOnDisk,
    quotaBytes: DATASTORE_QUOTA_BYTES,
    expiryMs: DATASTORE_EXPIRY_MS,
    liveGrants,
  };
  statsCache = { at: now, stats };
  return stats;
}

module.exports = {
  dataStoreStats,
  grantStorage,
  userForToken,
  loadUserData,
  saveUserData,
  sweepDataStores,
  startDataStoreSweeps,
  entryBytes,
};
