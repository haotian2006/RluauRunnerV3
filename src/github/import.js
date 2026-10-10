// Turns a GitHub URL into one .rbxm: a repository, a folder or file in it (built with
// Rojo's sync rules by build.luau under Lune), or a release .rbxm/.rbxmx asset. Wally
// packages go through wally.js and the same builder.
const path = require("path");
const zlib = require("zlib");
const { spawn } = require("child_process");
const { Readable } = require("stream");

const { PATH_TO_LUNE } = require("../config");
const { ImportError, SYNCED, MAX_FILE_BYTES, MAX_TOTAL_BYTES, MAX_FILES, FETCH_TIMEOUT_MS } = require("./common");
const { parseWallyTarget, buildWally } = require("./wally");

const BUILD_SCRIPT = path.join(__dirname, "build.luau");
const BUILD_TIMEOUT_MS = 20 * 1000;
const MAX_ARCHIVE_BYTES = 80 * 1024 * 1024;
const MAX_MODEL_BYTES = 20 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
const MAX_REF_TRIES = 4;
const CACHE_TTL_MS = 10 * 60 * 1000;
const CACHE_MAX_BYTES = 64 * 1024 * 1024;
const MAX_CONCURRENT = 2;
const MAX_QUEUED = 20;
const NAME = /^[A-Za-z0-9_.-]{1,100}$/;

function refCandidates(rest) {
  const out = [];
  for (let i = 1; i <= Math.min(rest.length, MAX_REF_TRIES); i++) {
    out.push({ ref: rest.slice(0, i).join("/"), path: rest.slice(i).join("/") });
  }
  return out;
}

function parseGithubUrl(raw) {
  let u;
  try {
    u = new URL(String(raw).trim());
  } catch {
    throw new ImportError("not a valid URL", 400);
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") {
    throw new ImportError("only http(s) URLs are supported", 400);
  }
  const host = u.hostname.toLowerCase();
  let segs;
  try {
    segs = u.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    throw new ImportError("not a valid URL", 400);
  }
  if (segs.some((s) => s === ".." || s === ".")) {
    throw new ImportError("not a valid URL", 400);
  }

  if (host === "raw.githubusercontent.com") {
    const [owner, repo, ...rest] = segs;
    if (!NAME.test(owner ?? "") || !NAME.test(repo ?? "") || rest.length < 2) {
      throw new ImportError("expected raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>", 400);
    }
    return { mode: "path", owner, repo, candidates: refCandidates(rest).filter((c) => c.path) };
  }
  if (host !== "github.com" && host !== "www.github.com") {
    throw new ImportError("only github.com and Wally URLs are supported", 400);
  }
  const [owner, repoRaw, kind, ...rest] = segs;
  const repo = (repoRaw ?? "").replace(/\.git$/i, "");
  if (!NAME.test(owner ?? "") || !NAME.test(repo)) {
    throw new ImportError("expected github.com/<owner>/<repo>", 400);
  }
  if (!kind) {
    return { mode: "repo", owner, repo, candidates: [{ ref: "HEAD", path: "" }] };
  }
  if (kind === "tree" || kind === "blob" || kind === "raw") {
    if (rest.length === 0) throw new ImportError(`missing branch after /${kind}/`, 400);
    return { mode: "path", owner, repo, candidates: refCandidates(rest) };
  }
  if (kind === "releases") {
    const download = rest[0] === "download" ? 1 : rest[0] === "latest" && rest[1] === "download" ? 2 : 0;
    const file = rest.at(-1) ?? "";
    if (download && rest.length > download && /\.rbxmx?$/i.test(file)) {
      const tail = rest.map(encodeURIComponent).join("/");
      return {
        mode: "model",
        owner,
        repo,
        url: `https://github.com/${owner}/${repo}/releases/${tail}`,
        name: file.replace(/\.rbxmx?$/i, ""),
      };
    }
    throw new ImportError("release URLs must point at a .rbxm or .rbxmx asset", 400);
  }
  throw new ImportError(`unsupported GitHub URL (/${kind}/)`, 400);
}

function limitedBody(res, max) {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) {
    throw new ImportError(`download is larger than ${Math.floor(max / 1024 / 1024)}MB`, 413);
  }
  let seen = 0;
  const source = Readable.fromWeb(res.body);
  source.on("data", (chunk) => {
    seen += chunk.length;
    if (seen > max) {
      source.destroy(new ImportError(`download is larger than ${Math.floor(max / 1024 / 1024)}MB`, 413));
    }
  });
  return source;
}

function octal(buf, start, len) {
  const s = buf.toString("latin1", start, start + len).replace(/\0.*$/, "").trim();
  return s ? parseInt(s, 8) : 0;
}

function cstring(buf, start, len) {
  return buf.toString("utf8", start, start + len).replace(/\0.*$/, "");
}

function parsePax(data) {
  const out = {};
  let i = 0;
  while (i < data.length) {
    const space = data.indexOf(0x20, i);
    if (space < 0) break;
    const len = parseInt(data.toString("latin1", i, space), 10);
    if (!len) break;
    const record = data.toString("utf8", space + 1, i + len - 1);
    const eq = record.indexOf("=");
    if (eq > 0) out[record.slice(0, eq)] = record.slice(eq + 1);
    i += len;
  }
  return out;
}

// Streams a .tar.gz and keeps the regular files Rojo can sync, keyed by their path with
// the archive's top folder stripped. Links and anything outside that folder are dropped.
async function readArchive(stream) {
  const files = new Map();
  let total = 0;
  let buf = Buffer.alloc(0);
  let state = "header";
  let entry = null;
  let remaining = 0;
  let pad = 0;
  let parts = null;
  let pax = {};
  let longName = null;
  let done = false;

  const finish = () => {
    const data = parts ? Buffer.concat(parts) : null;
    if (entry.type === "x") pax = parsePax(data);
    else if (entry.type === "L") longName = data.toString("utf8").replace(/\0.*$/, "");
    else if (data && entry.path) {
      files.set(entry.path, data);
    }
  };

  const gunzip = zlib.createGunzip();
  stream.on("error", (err) => gunzip.destroy(err));
  stream.pipe(gunzip);
  try {
    for await (const chunk of gunzip) {
      parse(chunk);
      if (done) break;
    }
  } finally {
    stream.destroy();
    gunzip.destroy();
  }
  return files;

  function parse(chunk) {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    while (!done) {
      if (state === "header") {
        if (buf.length < 512) break;
        const h = buf.subarray(0, 512);
        buf = buf.subarray(512);
        if (h.every((b) => b === 0)) {
          done = true;
          break;
        }
        const type = String.fromCharCode(h[156] || 0x30);
        const size = octal(h, 124, 12);
        let name = pax.path ?? longName;
        if (!name) {
          const prefix = cstring(h, 345, 155);
          name = (prefix ? prefix + "/" : "") + cstring(h, 0, 100);
        }
        if (type !== "x" && type !== "g" && type !== "L") {
          pax = {};
          longName = null;
        }
        entry = { type, size, path: null };
        parts = null;
        if (type === "x" || type === "g" || type === "L") {
          parts = [];
        } else if (type === "0" || type === "\0" || type === "7") {
          const segs = name.split("/").slice(1);
          const rel = segs.join("/");
          const safe = segs.length > 0 && !segs.some((s) => s === "" || s === "." || s === "..");
          if (safe && SYNCED.test(rel) && size <= MAX_FILE_BYTES) {
            if (files.size >= MAX_FILES) throw new ImportError(`the repository has more than ${MAX_FILES} files to sync`, 413);
            total += size;
            if (total > MAX_TOTAL_BYTES) throw new ImportError("the repository's synced files are too large", 413);
            entry.path = rel;
            parts = [];
          }
        }
        remaining = size;
        pad = (512 - (size % 512)) % 512;
        state = remaining > 0 ? "data" : "pad";
        if (remaining === 0) finish();
      } else if (state === "data") {
        const take = Math.min(remaining, buf.length);
        if (parts) parts.push(buf.subarray(0, take));
        buf = buf.subarray(take);
        remaining -= take;
        if (remaining > 0) break;
        finish();
        state = "pad";
      } else {
        const take = Math.min(pad, buf.length);
        buf = buf.subarray(take);
        pad -= take;
        if (pad > 0) break;
        state = "header";
      }
    }
  }
}

function frame(config, files) {
  const pieces = [];
  const push = (b) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(b.length);
    pieces.push(len, b);
  };
  push(Buffer.from(JSON.stringify(config)));
  for (const [p, data] of files) {
    push(Buffer.from(p));
    push(data);
  }
  return Buffer.concat(pieces);
}

function runBuild(config, files) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(PATH_TO_LUNE, ["run", BUILD_SCRIPT], { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    } catch (err) {
      reject(err);
      return;
    }
    const out = [];
    let outBytes = 0;
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new ImportError("building the model took too long", 504));
    }, BUILD_TIMEOUT_MS);
    child.stdout.on("data", (c) => {
      outBytes += c.length;
      if (outBytes > MAX_OUTPUT_BYTES) {
        child.kill("SIGKILL");
        return;
      }
      out.push(c);
    });
    child.stderr.on("data", (c) => {
      if (err.length < 4096) err += c.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (outBytes > MAX_OUTPUT_BYTES) return reject(new ImportError("the built model is too large", 413));
      if (code === 0) return resolve(Buffer.concat(out));
      reject(new ImportError(err.trim().split("\n")[0] || "the model failed to build"));
    });
    child.stdin.on("error", () => {});
    child.stdin.end(frame(config, files));
  });
}

async function fetchArchive(owner, repo, ref) {
  const url = `https://codeload.github.com/${owner}/${repo}/tar.gz/${ref.split("/").map(encodeURIComponent).join("/")}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
  if (res.status === 404) {
    res.body?.cancel().catch(() => {});
    return null;
  }
  if (!res.ok) {
    res.body?.cancel().catch(() => {});
    throw new ImportError(`GitHub returned ${res.status}`, 502);
  }
  return readArchive(limitedBody(res, MAX_ARCHIVE_BYTES));
}

async function build(target) {
  if (target.mode === "model") {
    const res = await fetch(target.url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    if (res.status === 404) throw new ImportError("release asset not found", 404);
    if (!res.ok) throw new ImportError(`GitHub returned ${res.status}`, 502);
    const host = new URL(res.url).hostname;
    if (host !== "github.com" && !host.endsWith(".githubusercontent.com")) {
      throw new ImportError("release asset redirected off GitHub", 502);
    }
    const chunks = [];
    for await (const c of limitedBody(res, MAX_MODEL_BYTES)) chunks.push(c);
    return runBuild({ mode: "model", name: target.name }, new Map([["model", Buffer.concat(chunks)]]));
  }
  for (const { ref, path: p } of target.candidates) {
    const files = await fetchArchive(target.owner, target.repo, ref);
    if (!files) continue;
    const config = p
      ? { mode: "path", path: p.replace(/\/+$/, ""), name: target.repo }
      : { mode: "repo", name: target.repo };
    return runBuild(config, files);
  }
  throw new ImportError(
    target.mode === "repo" ? "repository not found (or it's private)" : "branch, tag or commit not found",
    404,
  );
}

const cache = new Map();
let cacheBytes = 0;
let running = 0;
const waiting = [];

function remember(key, bytes) {
  while (cacheBytes + bytes.length > CACHE_MAX_BYTES && cache.size > 0) {
    const [oldKey, old] = cache.entries().next().value;
    cache.delete(oldKey);
    cacheBytes -= old.bytes.length;
  }
  if (bytes.length <= CACHE_MAX_BYTES) {
    cache.set(key, { bytes, expires: Date.now() + CACHE_TTL_MS });
    cacheBytes += bytes.length;
  }
}

async function withSlot(fn) {
  if (running >= MAX_CONCURRENT) {
    if (waiting.length >= MAX_QUEUED) throw new ImportError("too many imports in progress, try again shortly", 503);
    await new Promise((r) => waiting.push(r));
  }
  running++;
  try {
    return await fn();
  } finally {
    running--;
    waiting.shift()?.();
  }
}

const inflight = new Map();

async function importModel(rawUrl) {
  const target = parseWallyTarget(rawUrl) ?? parseGithubUrl(rawUrl);
  const key = JSON.stringify(target);
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return hit.bytes;
  let pending = inflight.get(key);
  if (!pending) {
    pending = withSlot(() => (target.mode === "wally" ? buildWally(target, runBuild) : build(target)))
      .then((bytes) => {
        remember(key, bytes);
        return bytes;
      })
      .finally(() => inflight.delete(key));
    inflight.set(key, pending);
  }
  return pending;
}

module.exports = { importModel, parseGithubUrl, readArchive, runBuild, ImportError, _cache: cache };
