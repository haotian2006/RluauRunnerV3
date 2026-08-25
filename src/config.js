const fs = require("fs");
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

const ENABLE_DISCORD = envFlag("ENABLE_DISCORD", true);
const ENABLE_WEB = envFlag("ENABLE_WEB", false);

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

  DISCORD_TOKEN: process.env.BOT_TOKEN,
  DISCORD_APP_ID: process.env.CLIENT_ID,
  PORT: process.env.PORT || 3000,
  CALLBACK_URL,
  ENABLE_DISCORD,
  ENABLE_WEB,

  RESOURCES_URL:
    "https://api.github.com/repos/haotian2006/luau-runner-bot-resources/contents/resources?ref=main",
  FORM_URL: `https://docs.google.com/forms/d/e/${FORM_ID}/formResponse`,

  SERVER_CREATION_COOL_DOWN: 1000 * 20,

  SERVER_RUN_TIME_MAX: 1000 * 60 * 1.5,
  SERVER_CHECK_INTERVAL: 1000,
  SERVER_PING_TIMEOUT: 1000 * 5,

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
