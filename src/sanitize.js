const os = require("os");
const path = require("path");

const ROOT_DIR = path.join(__dirname, "..");
const TMP_DIR = os.tmpdir();

function variants(value) {
  return [value, value.replace(/\\/g, "/"), value.replace(/\//g, "\\")];
}

const REPLACEMENTS = [
  ...variants(ROOT_DIR).map((from) => [from, "."]),
  ...variants(TMP_DIR).map((from) => [from, "<tmp>"]),
];

function stripHostPaths(text) {
  if (typeof text !== "string" || !text) return text;
  let result = text;
  for (const [from, to] of REPLACEMENTS) {
    if (result.includes(from)) result = result.split(from).join(to);
  }
  return result;
}

/** Sanitized message for an Error, or for anything thrown that is not one. */
function safeMessage(error) {
  const message =
    error instanceof Error ? error.message : String(error?.message ?? error);
  return stripHostPaths(message) || "Unknown error";
}

module.exports = { stripHostPaths, safeMessage };
