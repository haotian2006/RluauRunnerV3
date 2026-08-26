const { wait } = require("../util");

const MAX_RECV_BYTES = 12 * 1024 * 1024;

const MAX_SECTIONS = 256;

const ENTRY_TTL_MS = 80000;
const WAIT_TIMEOUT_MS = 60 * 1000;
const POLL_INTERVAL_MS = 500;

const uploads = new Map();

class ChunkRejected extends Error {
  constructor(message) {
    super(message);
    this.name = "ChunkRejected";
  }
}

function dropUpload(id) {
  const entry = uploads.get(id);
  if (entry) {
    clearTimeout(entry.timer);
    uploads.delete(id);
  }
}

function addChunk(id, index, chunk) {
  if (typeof id !== "string" && typeof id !== "number") {
    throw new ChunkRejected("token must be a string or number");
  }
  if (!Number.isInteger(index) || index < 0 || index >= MAX_SECTIONS) {
    throw new ChunkRejected(`index must be an integer in [0, ${MAX_SECTIONS})`);
  }
  if (typeof chunk !== "string") {
    throw new ChunkRejected("chunk must be a string");
  }

  const key = String(id);
  let entry = uploads.get(key);
  if (!entry) {
    entry = {
      chunks: new Map(),
      bytes: 0,
      timer: setTimeout(() => uploads.delete(key), ENTRY_TTL_MS),
    };
    uploads.set(key, entry);
  }

  const previous = entry.chunks.get(index);
  const delta = chunk.length - (previous ? previous.length : 0);
  if (entry.bytes + delta > MAX_RECV_BYTES) {
    dropUpload(key);
    throw new ChunkRejected(
      `upload exceeds the maximum size of ${Math.floor(MAX_RECV_BYTES / 1024)} KB`,
    );
  }

  entry.chunks.set(index, chunk);
  entry.bytes += delta;
  return entry.chunks.size;
}

function receivedCount(id) {
  return uploads.get(String(id))?.chunks.size ?? 0;
}

async function waitForUpload(id, numSections) {
  const key = String(id);
  const deadline = Date.now() + WAIT_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const entry = uploads.get(key);
    if (entry && entry.chunks.size >= numSections) {
      const ordered = [...entry.chunks.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([, data]) => data);
      dropUpload(key);
      return {
        success: true,
        data: ordered.join(""),
        received: ordered.length,
      };
    }
    await wait(POLL_INTERVAL_MS);
  }

  const received = receivedCount(key);
  dropUpload(key);
  return { success: false, data: null, received };
}

module.exports = { MAX_SECTIONS, ChunkRejected, addChunk, waitForUpload };
