const crypto = require("crypto");

const { noteWorkerIp } = require("../origin");
const { SECRET_TOKEN } = require("../state");

const EXPECTED = Buffer.from(SECRET_TOKEN, "utf8");

function matchesSecret(provided) {
  if (typeof provided !== "string") return false;
  const given = Buffer.from(provided, "utf8");
  if (given.length !== EXPECTED.length) return false;
  return crypto.timingSafeEqual(given, EXPECTED);
}

function requireSecret(req, res, next) {
  if (!matchesSecret(req.headers["x-secret-token"])) {
    return res.status(403).json({ message: "Forbidden" });
  }
  // Only the worker pool holds the secret, so this is where the public API
  // learns which addresses are Roblox.
  noteWorkerIp(req.ip);
  next();
}

module.exports = { requireSecret, matchesSecret };
