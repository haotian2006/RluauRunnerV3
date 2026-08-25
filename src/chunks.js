const zlib = require("zlib");
const zstd = require("zstd-napi");
const { FILE_CHUNK_SIZE, MAX_DATA_TO_SEND } = require("./config");
const { logBot } = require("./log");

const MAX_DECODED_BYTES = 64 * 1024 * 1024;

const CHUNK_TO_DATA = {};
let CHUNK_ID = 0;

function encodeZstd(input) {
  let buffer;

  if (Buffer.isBuffer(input)) {
    buffer = input;
  } else if (typeof input === "string") {
    buffer = Buffer.from(input, "utf-8");
  } else {
    logBot("Encode Zstd Error", "Input is not a string or Buffer");
    throw new TypeError("Input must be a string or Buffer");
  }

  const compressed = zstd.compress(buffer, 10);
  return compressed.toString("base64");
}

function decodeBuffer(data) {
  if (!data || typeof data !== "object") {
    throw new TypeError("Expected a { zbase64 } or { base64 } envelope");
  }
  if (data.zbase64) {
    if (typeof data.zbase64 !== "string") {
      throw new TypeError("zbase64 must be a string");
    }
    try {
      return zlib.zstdDecompressSync(Buffer.from(data.zbase64, "base64"), {
        maxOutputLength: MAX_DECODED_BYTES,
      });
    } catch (err) {
      throw new Error(`Failed to decompress payload: ${err.message}`);
    }
  }
  if (data.base64) {
    if (typeof data.base64 !== "string") {
      throw new TypeError("base64 must be a string");
    }
    return Buffer.from(data.base64, "base64");
  }
  throw new Error("Envelope contained neither zbase64 nor base64");
}

const CHUNK_TTL_MS = 60 * 1000;

const wireCache = new WeakMap();

function releaseChunks(info, entry) {
  clearTimeout(entry.timer);
  for (const id of entry.ids) {
    delete CHUNK_TO_DATA[id];
  }
  wireCache.delete(info);
}

function scheduleRelease(info, entry) {
  entry.timer = setTimeout(() => releaseChunks(info, entry), CHUNK_TTL_MS);
}

function toWirePayload(info) {
  const content = info.content;
  if (typeof content !== "string") {
    return info;
  }

  if (content.length <= FILE_CHUNK_SIZE) {
    return info;
  }

  if (content.length > MAX_DATA_TO_SEND) {
    return {
      ...info,
      content:
        "Data too large. Must be less than " +
        MAX_DATA_TO_SEND +
        " characters.",
    };
  }

  const cached = wireCache.get(info);
  if (cached) {
    clearTimeout(cached.timer);
    scheduleRelease(info, cached);
    return { ...info, content: cached.ids };
  }

  const ids = [];
  const totalChunks = Math.ceil(content.length / FILE_CHUNK_SIZE);
  for (let i = 0; i < totalChunks; i++) {
    const start = i * FILE_CHUNK_SIZE;
    const chunk = content.slice(start, start + FILE_CHUNK_SIZE);
    const id = CHUNK_ID.toString();
    CHUNK_TO_DATA[id] = chunk;
    ids.push(id);
    CHUNK_ID++;
  }

  const entry = { ids, timer: null };
  wireCache.set(info, entry);
  scheduleRelease(info, entry);

  return { ...info, content: ids };
}

function getChunk(id) {
  return CHUNK_TO_DATA[id];
}

function hasChunk(id) {
  return id in CHUNK_TO_DATA;
}

module.exports = {
  encodeZstd,
  decodeBuffer,
  toWirePayload,
  getChunk,
  hasChunk,
};
