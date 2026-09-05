const fs = require("fs");
const os = require("os");
const path = require("path");

require("dotenv").config();

const ROOT_DIR = path.join(__dirname, "..");

function resolveExec(name) {
  const base = path.join(ROOT_DIR, "bin", name);
  if (process.platform === "win32") {
    const withExe = base + ".exe";
    if (fs.existsSync(withExe)) return withExe;
  }
  return base;
}

const FORM_ID = process.env.FORM_ID;

const BOT_SRC_PATH = path.join(ROOT_DIR, "luauBot.b64");

function loadBotSource() {
  if (!fs.existsSync(BOT_SRC_PATH)) {
    return { error: `${BOT_SRC_PATH} does not exist` };
  }
  const encoded = fs.readFileSync(BOT_SRC_PATH, "utf-8").trim();
  if (!encoded) {
    return { error: `${BOT_SRC_PATH} is empty` };
  }

  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length === 0 || decoded.toString("base64").length === 0) {
    return { error: `${BOT_SRC_PATH} is not valid base64` };
  }
  return { encoded };
}

const botSrc = loadBotSource();
if (botSrc.error) {
  console.error(
    `Fatal: ${botSrc.error}\n` +
      "luauBot.b64 is required. Generate it with the EncodingService snippet in readme.md " +
      "and place it in the project root.",
  );
  process.exit(1);
}

const botSrcEncoded = botSrc.encoded;

function loadCallbackUrl() {
  const raw = process.env.CALLBACK_URL || process.env.TUNNEL_URL;
  if (!process.env.CALLBACK_URL && process.env.TUNNEL_URL) {
    console.warn(
      "Warning: TUNNEL_URL is deprecated, rename it to CALLBACK_URL in .env.",
    );
  }
  if (!raw || !raw.trim()) {
    return { error: "CALLBACK_URL is not set" };
  }

  const trimmed = raw.trim();
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    return {
      error: `CALLBACK_URL is not a valid URL: ${trimmed} (include the scheme, e.g. http://host:3000)`,
    };
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return {
      error: `CALLBACK_URL must be http or https, got ${parsed.protocol}`,
    };
  }

  return { url: trimmed.replace(/\/+$/, "") };
}

// Missing tools are not fatal: /compile still works, since that runs in
// Roblox. Only bytecode, analyze, ast and format need them.
function missingTools() {
  const tools = [
    ["luau-compile", resolveExec("luau-compile")],
    ["luau-analyze", resolveExec("luau-analyze")],
    ["luau-ast", resolveExec("luau-ast")],
    ["stylua", resolveExec("stylua")],
  ];

  if (envFlag("ENABLE_LOCAL_EXEC", false)) {
    tools.push(["lune", resolveExec("lune")]);
  }
  return tools.filter(([, p]) => !fs.existsSync(p)).map(([name]) => name);
}

const callback = loadCallbackUrl();
if (callback.error) {
  console.error(
    `Fatal: ${callback.error}
` +
      "Set CALLBACK_URL in .env to the address the Roblox session should reach " +
      "this server at, e.g. http://203.0.113.10:3000",
  );
  process.exit(1);
}

const CALLBACK_URL = callback.url;

function envFlag(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = raw.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(value)) return true;
  if (["0", "false", "no", "off"].includes(value)) return false;
  console.warn(
    `Warning: ${name}="${raw}" is not a boolean, using ${fallback}.`,
  );
  return fallback;
}

function envNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    console.warn(
      `Warning: ${name}="${raw}" is not a positive number, using ${fallback}.`,
    );
    return fallback;
  }
  return value;
}

function loadTrustProxy() {
  const raw = process.env.TRUST_PROXY;
  if (raw === undefined || raw.trim() === "") return false;
  const trimmed = raw.trim();
  if (["0", "false", "no", "off"].includes(trimmed.toLowerCase())) return false;
  const asNumber = Number(trimmed);
  return Number.isFinite(asNumber) ? asNumber : trimmed;
}

const TRUST_PROXY = loadTrustProxy();

const ENABLE_DISCORD = envFlag("ENABLE_DISCORD", true);
const ENABLE_WEB = envFlag("ENABLE_WEB", false);

const ENABLE_LOCAL_EXEC = envFlag("ENABLE_LOCAL_EXEC", false);
if (ENABLE_LOCAL_EXEC && process.platform === "win32") {
  console.warn(
    "Warning: ENABLE_LOCAL_EXEC is on, but memory limits for sandboxed scripts " +
      "are not enforceable on Windows (no ulimit). A script can allocate until " +
      "the host runs out. Use the timeout and concurrency caps as the only bound.",
  );
}

const LOCAL_CPU_QUOTA_PERCENT = Math.max(
  0,
  Math.floor(envNumber("LOCAL_CPU_QUOTA_PERCENT", 0)),
);
if (
  ENABLE_LOCAL_EXEC &&
  LOCAL_CPU_QUOTA_PERCENT &&
  process.platform === "win32"
) {
  console.warn(
    "Warning: LOCAL_CPU_QUOTA_PERCENT is set, but CPU quotas need systemd-run " +
      "and are not enforceable on Windows. Sandboxed scripts can use full CPU.",
  );
}

const LOCAL_ISOLATION_MODES = ["scope", "service", "none"];
let LOCAL_ISOLATION = (process.env.LOCAL_ISOLATION || "scope")
  .trim()
  .toLowerCase();
if (!LOCAL_ISOLATION_MODES.includes(LOCAL_ISOLATION)) {
  console.warn(
    `Warning: LOCAL_ISOLATION="${process.env.LOCAL_ISOLATION}" is not one of ` +
      `${LOCAL_ISOLATION_MODES.join("/")}, using scope.`,
  );
  LOCAL_ISOLATION = "scope";
}
if (process.platform === "win32") LOCAL_ISOLATION = "none";

// Transient units run as root unless told otherwise, which would hand the
// sandbox more privilege than scope mode gives it. Default to whoever the bot
// runs as, since that user owns the per-job tmpdir.
const LOCAL_SANDBOX_USER = (
  process.env.LOCAL_SANDBOX_USER || os.userInfo().username
).trim();

// ProtectHome=yes makes /home inaccessible to the unit, and a BindReadOnlyPaths
// for a file underneath it does NOT punch back through (verified on the box:
// execve fails with 203/EXEC). So service mode runs a copy of lune staged
// outside /home; sandbox.luau is copied into the job's tmpdir per run.
const LOCAL_LUNE_STAGED_PATH = (
  process.env.LOCAL_LUNE_STAGED_PATH || "/opt/luau-runner/bin/lune"
).trim();
if (
  ENABLE_LOCAL_EXEC &&
  LOCAL_ISOLATION === "service" &&
  !fs.existsSync(LOCAL_LUNE_STAGED_PATH)
) {
  console.error(
    `Fatal: LOCAL_ISOLATION=service needs lune staged outside /home, but ` +
      `${LOCAL_LUNE_STAGED_PATH} does not exist.\n` +
      "Install it with:\n" +
      `  sudo install -D -m 0755 ${resolveExec("lune")} ${LOCAL_LUNE_STAGED_PATH}\n` +
      "or set LOCAL_ISOLATION=scope to fall back to cgroup-only limits.",
  );
  process.exit(1);
}

if (!ENABLE_DISCORD && !ENABLE_WEB) {
  console.error(
    "Fatal: both ENABLE_DISCORD and ENABLE_WEB are false, so there is nothing to serve.\n" +
      "Enable at least one front end in .env.",
  );
  process.exit(1);
}

// BOT_TOKEN only matters when the bot itself runs; a web-only deployment
// should not need Discord credentials at all.
if (ENABLE_DISCORD && !process.env.BOT_TOKEN) {
  console.error(
    "Fatal: BOT_TOKEN is not set.\n" +
      "Set it in .env, or set ENABLE_DISCORD=false to run the web front end alone.",
  );
  process.exit(1);
}

module.exports = {
  ROOT_DIR,

  PATH_TO_COMPILER: resolveExec("luau-compile"),
  PATH_TO_ANALYZER: resolveExec("luau-analyze"),
  PATH_TO_AST: resolveExec("luau-ast"),
  PATH_TO_FORMATTER: resolveExec("stylua"),
  PATH_TO_LUNE: resolveExec("lune"),

  DISCORD_TOKEN: process.env.BOT_TOKEN,
  DISCORD_APP_ID: process.env.CLIENT_ID,
  PORT: process.env.PORT || 3000,
  CALLBACK_URL,
  ENABLE_DISCORD,
  ENABLE_WEB,
  TRUST_PROXY,
  missingTools,

  ENABLE_LOCAL_EXEC,

  LOCAL_TIMEOUT_MS: envNumber("LOCAL_TIMEOUT_MS", 30000),
  LOCAL_FORCED_TIMEOUT_MS: envNumber("LOCAL_FORCED_TIMEOUT_MS", 60000),
  LOCAL_HEARTBEAT_TIMEOUT_MS: envNumber("LOCAL_HEARTBEAT_TIMEOUT_MS", 11000),
  // Enforced by ulimit on Linux only; ignored on Windows.
  LOCAL_MEMORY_LIMIT_MB: envNumber("LOCAL_MEMORY_LIMIT_MB", 256),
  // Percent of one core, enforced via systemd-run --scope on Linux only.
  // 0 disables the quota. 100 = 1 full core.
  LOCAL_CPU_QUOTA_PERCENT,
  LOCAL_ISOLATION,
  LOCAL_LUNE_STAGED_PATH,
  LOCAL_SANDBOX_USER,

  LOCAL_MAX_CONCURRENT: envNumber("LOCAL_MAX_CONCURRENT", 2),
  LOCAL_MAX_LINES: envNumber("LOCAL_MAX_LINES", 2000),
  LOCAL_MAX_LINE_BYTES: envNumber("LOCAL_MAX_LINE_BYTES", 4000),

  RESOURCES_URL:
    "https://api.github.com/repos/haotian2006/luau-runner-bot-resources/contents/resources?ref=main",
  // Logging is optional: without FORM_ID nothing is sent anywhere.
  FORM_URL: FORM_ID
    ? `https://docs.google.com/forms/d/e/${FORM_ID}/formResponse`
    : null,
  FORM_ENTRIES: {
    name: process.env.FORM_ENTRY_NAME || "entry.1569623480",
    userId: process.env.FORM_ENTRY_USER_ID || "entry.1249804528",
    command: process.env.FORM_ENTRY_COMMAND || "entry.726094871",
    data: process.env.FORM_ENTRY_DATA || "entry.182293982",
  },

  SERVER_CREATION_COOL_DOWN: 1000 * 20,

  MAX_ROBLOX_WORKERS: Math.max(
    1,
    Math.floor(envNumber("MAX_ROBLOX_WORKERS", 4)),
  ),

  SERVER_RUN_TIME_MAX: 1000 * 60 * 3,
  SERVER_CHECK_INTERVAL: 1000,
  SERVER_PING_TIMEOUT: 1000 * 5,
  SERVER_RECOVERY_GRACE_MS: 1000 * 40,

  SERVER_TIME_OUT: "300s",

  FILE_CHUNK_SIZE: 1024 * 1024 * 10, // 10 MB
  MAX_DATA_TO_SEND: 1024 * 1024 * 100, // 100 MB
  MAX_RESPONSE_FILES: 8,

  BODY_LIMIT: "50mb",

  FILTER_BAD_WORDS: true,
  botSrcEncoded,

  SupportedFileTypes: new Set([
    "png",
    "jpg",
    "jpeg",
    "gif",
    "webp",
    "svg",
    "txt",
    "ansi",
    "lua",
    "luau",
    "json",
    "xml",
    "html",
    "css",
    "js",
    "md",
    "csv",
    "mp3",
    "wav",
    "ogg",
    "mp4",
    "webm",
    "rbxm",
  ]),
};
