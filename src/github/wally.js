// Wally packages: resolves a package and its dependencies the way `wally install` does
// and builds them in Wally's layout, _Index/<scope>_<name>@<version>/<name> with a link
// module per dependency, so packages keep requiring script.Parent.<Dependency>.
const zlib = require("zlib");

const { ImportError, SYNCED, MAX_FILE_BYTES, MAX_TOTAL_BYTES, MAX_FILES, FETCH_TIMEOUT_MS } = require("./common");

const API = "https://api.wally.run/v1";
const WALLY_VERSION = "0.3.2";
const MAX_PACKAGES = 50;
const MAX_ZIP_BYTES = 10 * 1024 * 1024;
const METADATA_TTL_MS = 10 * 60 * 1000;
const PART = /^[a-z0-9_-]{1,64}$/;

// "wally:scope/name@req" or https://wally.run/package/scope/name?version=x.y.z
function parseWallyTarget(raw) {
  const text = String(raw).trim();
  let spec;
  if (/^wally:/i.test(text)) {
    spec = text.slice(6);
  } else {
    let u;
    try {
      u = new URL(text);
    } catch {
      return null;
    }
    if (u.hostname.toLowerCase() !== "wally.run" && u.hostname.toLowerCase() !== "www.wally.run") return null;
    const segs = u.pathname.split("/").filter(Boolean);
    if (segs[0] !== "package" || segs.length !== 3) {
      throw new ImportError("expected wally.run/package/<scope>/<name>", 400);
    }
    const version = u.searchParams.get("version");
    spec = `${segs[1]}/${segs[2]}${version ? `@=${version}` : ""}`;
  }
  const at = spec.indexOf("@");
  const id = (at < 0 ? spec : spec.slice(0, at)).trim().toLowerCase();
  const req = at < 0 ? "*" : spec.slice(at + 1).trim() || "*";
  const [scope, name, extra] = id.split("/");
  if (!PART.test(scope ?? "") || !PART.test(name ?? "") || extra !== undefined) {
    throw new ImportError("expected wally:<scope>/<name>@<version>", 400);
  }
  parseRequirement(req);
  return { mode: "wally", scope, name, req };
}

//// versions

function parseVersion(text) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(String(text).trim());
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ?? null, text: String(text).trim() };
}

function comparePre(a, b) {
  const x = a.split("."),
    y = b.split(".");
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if (x[i] === undefined) return -1;
    if (y[i] === undefined) return 1;
    const nx = /^\d+$/.test(x[i]),
      ny = /^\d+$/.test(y[i]);
    if (nx && ny && +x[i] !== +y[i]) return +x[i] - +y[i];
    if (nx !== ny) return nx ? -1 : 1;
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}

function compare(a, b) {
  return (
    a.major - b.major ||
    a.minor - b.minor ||
    a.patch - b.patch ||
    (a.pre === b.pre ? 0 : a.pre === null ? 1 : b.pre === null ? -1 : comparePre(a.pre, b.pre))
  );
}

const v = (major, minor, patch, pre = null) => ({ major, minor, patch, pre });

// Cargo-style requirements, which Wally uses: comma-separated comparators, bare means ^.
function parseRequirement(req) {
  const text = String(req).trim();
  if (text === "" || text === "*") return { tests: [() => true], pre: false };
  const tests = [];
  let pre = false;
  for (const part of text.split(",")) {
    const m = /^(\^|~|>=|<=|>|<|=)?\s*v?(\d+)(?:\.(\d+|\*|x))?(?:\.(\d+|\*|x))?(?:-([0-9A-Za-z.-]+))?$/i.exec(part.trim());
    if (!m) throw new ImportError(`can't read the version requirement "${text}"`, 400);
    const op = m[1] ?? "^";
    const major = +m[2];
    const minor = m[3] === undefined || /[*x]/i.test(m[3]) ? null : +m[3];
    const patch = m[4] === undefined || /[*x]/i.test(m[4]) ? null : +m[4];
    if (m[5]) pre = true;
    const low = v(major, minor ?? 0, patch ?? 0, m[5] ?? null);
    const next = minor === null ? v(major + 1, 0, 0) : patch === null ? v(major, minor + 1, 0) : null;
    const ge = (x) => compare(x, low) >= 0;
    const lt = (b) => (x) => compare(x, b) < 0;
    if (op === "=") {
      tests.push(next ? (x) => ge(x) && lt(next)(x) : (x) => compare(x, low) === 0);
    } else if (op === ">=") {
      tests.push(ge);
    } else if (op === ">") {
      tests.push(next ? (x) => compare(x, next) >= 0 : (x) => compare(x, low) > 0);
    } else if (op === "<") {
      tests.push(lt(low));
    } else if (op === "<=") {
      tests.push(next ? lt(next) : (x) => compare(x, low) <= 0);
    } else if (op === "~") {
      const upper = minor === null ? v(major + 1, 0, 0) : v(major, minor + 1, 0);
      tests.push((x) => ge(x) && lt(upper)(x));
    } else {
      let upper;
      if (major > 0 || minor === null) upper = v(major + 1, 0, 0);
      else if (minor > 0 || patch === null) upper = v(0, minor + 1, 0);
      else upper = v(0, 0, patch + 1);
      tests.push((x) => ge(x) && lt(upper)(x));
    }
  }
  return { tests, pre };
}

function pickVersion(versions, req) {
  const { tests, pre } = parseRequirement(req);
  let best = null;
  for (const entry of versions) {
    const ver = parseVersion(entry.package?.version);
    if (!ver || (ver.pre && !pre)) continue;
    if (!tests.every((t) => t(ver))) continue;
    if (!best || compare(ver, best.ver) > 0) best = { ver, entry };
  }
  return best;
}

//// registry

const metadataCache = new Map();

async function metadata(scope, name) {
  const key = `${scope}/${name}`;
  const hit = metadataCache.get(key);
  if (hit && hit.expires > Date.now()) return hit.versions;
  const res = await fetch(`${API}/package-metadata/${scope}/${name}`, {
    headers: { "Wally-Version": WALLY_VERSION },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  // the registry answers 500, not 404, for a package that doesn't exist
  if (res.status === 404 || res.status === 500) {
    throw new ImportError(`Wally package ${key} not found (registry returned ${res.status})`, 404);
  }
  if (!res.ok) throw new ImportError(`the Wally registry returned ${res.status}`, 502);
  const versions = (await res.json())?.versions;
  if (!Array.isArray(versions)) throw new ImportError(`the Wally registry sent no versions for ${key}`, 502);
  metadataCache.set(key, { versions, expires: Date.now() + METADATA_TTL_MS });
  return versions;
}

async function contents(scope, name, version) {
  const res = await fetch(`${API}/package-contents/${scope}/${name}/${version}`, {
    headers: { "Wally-Version": WALLY_VERSION },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) throw new ImportError(`couldn't download ${scope}/${name}@${version} (${res.status})`, 502);
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_ZIP_BYTES) {
    throw new ImportError(`${scope}/${name}@${version} is larger than 10MB`, 413);
  }
  const bytes = Buffer.from(await res.arrayBuffer());
  if (bytes.length > MAX_ZIP_BYTES) throw new ImportError(`${scope}/${name}@${version} is larger than 10MB`, 413);
  return bytes;
}

// Reads a zip's regular files that Rojo can sync. Only stored and deflated entries.
function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new ImportError("a package download isn't a zip archive", 502);
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const files = new Map();
  let total = 0;
  for (let n = 0; n < count; n++) {
    if (p + 46 > buf.length || buf.readUInt32LE(p) !== 0x02014b50) {
      throw new ImportError("a package download is a damaged zip", 502);
    }
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nameLen);
    p += 46 + nameLen + extraLen + commentLen;
    const segs = name.split("/");
    if (name.endsWith("/") || name.includes("\\") || segs.some((s) => s === "" || s === "." || s === "..")) continue;
    if (!SYNCED.test(name) || usize > MAX_FILE_BYTES || (method !== 0 && method !== 8)) continue;
    if (local + 30 > buf.length || buf.readUInt32LE(local) !== 0x04034b50) {
      throw new ImportError("a package download is a damaged zip", 502);
    }
    const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const raw = buf.subarray(start, start + csize);
    const data = method === 0 ? Buffer.from(raw) : zlib.inflateRawSync(raw, { maxOutputLength: MAX_FILE_BYTES });
    total += data.length;
    if (files.size >= MAX_FILES || total > MAX_TOTAL_BYTES) {
      throw new ImportError("the packages' files are too large", 413);
    }
    files.set(name, data);
  }
  return files;
}

//// build

const indexKey = (scope, name, version) => `${scope}_${name}@${version}`;

function splitDependency(alias, spec) {
  const at = String(spec).indexOf("@");
  const id = (at < 0 ? spec : spec.slice(0, at)).trim().toLowerCase();
  const [scope, name] = id.split("/");
  if (!PART.test(scope ?? "") || !PART.test(name ?? "")) {
    throw new ImportError(`dependency ${alias} has an unreadable spec "${spec}"`, 422);
  }
  return { scope, name, req: at < 0 ? "*" : spec.slice(at + 1).trim() || "*" };
}

async function resolve(target) {
  const packages = new Map();
  const visit = async (scope, name, req) => {
    const versions = await metadata(scope, name);
    const best = pickVersion(versions, req);
    if (!best) throw new ImportError(`no version of ${scope}/${name} matches "${req}"`, 404);
    const key = indexKey(scope, name, best.ver.text);
    if (packages.has(key)) return key;
    if (packages.size >= MAX_PACKAGES) throw new ImportError(`more than ${MAX_PACKAGES} packages in the dependency tree`, 413);
    const pkg = { key, scope, name, version: best.ver.text, deps: {} };
    packages.set(key, pkg);
    // a server is running the code, so shared and server dependencies both apply
    const deps = { ...(best.entry["server-dependencies"] ?? {}), ...(best.entry.dependencies ?? {}) };
    for (const [alias, spec] of Object.entries(deps)) {
      const d = splitDependency(alias, spec);
      pkg.deps[alias] = await visit(d.scope, d.name, d.req);
    }
    return key;
  };
  const root = await visit(target.scope, target.name, target.req);
  return { root, packages: [...packages.values()] };
}

async function buildWally(target, runBuild) {
  const { root, packages } = await resolve(target);
  const files = new Map();
  await Promise.all(
    packages.map(async (pkg) => {
      const zip = readZip(await contents(pkg.scope, pkg.name, pkg.version));
      for (const [p, data] of zip) files.set(`${pkg.key}/${p}`, data);
    }),
  );
  let total = 0;
  for (const data of files.values()) total += data.length;
  if (files.size > MAX_FILES || total > MAX_TOTAL_BYTES) throw new ImportError("the packages' files are too large", 413);
  return runBuild(
    {
      mode: "wally",
      root,
      name: target.name,
      packages: packages.map((p) => ({ key: p.key, name: p.name, deps: p.deps })),
    },
    files,
  );
}

module.exports = { parseWallyTarget, parseRequirement, pickVersion, readZip, buildWally, _resolve: resolve };
