const crypto = require("crypto");

const { STATS_PASSWORD } = require("../config");

const SESSION_TTL_MS = 1000 * 60 * 60 * 12;
const COOKIE_NAME = "status_session";
const MAX_SESSIONS = 100;
// Slow enough that guessing is hopeless over a network, loose enough that a
// fat-fingered password a few times running is not a lockout.
const ATTEMPT_LIMIT = 8;
const ATTEMPT_WINDOW_MS = 1000 * 60 * 15;

/** session id -> expiry. Cleared by restart, which is the intent. */
const sessions = new Map();
const attempts = new Map();

function enabled() {
  return typeof STATS_PASSWORD === "string" && STATS_PASSWORD.length > 0;
}

/**
 * Compare without leaking the answer through timing. Both sides are hashed
 * first so the comparison is over equal-length buffers whatever was submitted -
 * timingSafeEqual throws on a length mismatch, and the mismatch itself would
 * otherwise say how long the password is.
 */
function matchesPassword(provided) {
  if (!enabled() || typeof provided !== "string") return false;
  const given = crypto.createHash("sha256").update(provided).digest();
  const expected = crypto.createHash("sha256").update(STATS_PASSWORD).digest();
  return crypto.timingSafeEqual(given, expected);
}

function pruneSessions(now = Date.now()) {
  for (const [id, expiresAt] of sessions) {
    if (expiresAt <= now) sessions.delete(id);
  }
}

function createSession(now = Date.now()) {
  pruneSessions(now);
  if (sessions.size >= MAX_SESSIONS) {
    sessions.delete(sessions.keys().next().value);
  }
  const id = crypto.randomBytes(32).toString("hex");
  sessions.set(id, now + SESSION_TTL_MS);
  return id;
}

function parseCookies(header) {
  const jar = {};
  if (typeof header !== "string") return jar;
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    const name = part.slice(0, index).trim();
    if (!name) continue;
    jar[name] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return jar;
}

function hasSession(req, now = Date.now()) {
  const id = parseCookies(req.headers?.cookie)[COOKIE_NAME];
  if (!id) return false;
  const expiresAt = sessions.get(id);
  if (!expiresAt) return false;
  if (expiresAt <= now) {
    sessions.delete(id);
    return false;
  }
  return true;
}

function dropSession(req) {
  const id = parseCookies(req.headers?.cookie)[COOKIE_NAME];
  if (id) sessions.delete(id);
}

/** Secure is conditional: over plain http the browser would drop the cookie. */
function setSessionCookie(req, res, id) {
  const secure = req.secure || req.headers?.["x-forwarded-proto"] === "https";
  const parts = [
    `${COOKIE_NAME}=${id}`,
    "HttpOnly",
    "SameSite=Strict",
    "Path=/",
    `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
  ];
  if (secure) parts.push("Secure");
  res.setHeader("Set-Cookie", parts.join("; "));
}

function clearSessionCookie(res) {
  res.setHeader(
    "Set-Cookie",
    `${COOKIE_NAME}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`,
  );
}

/** Attempts are counted per address so one guesser cannot lock everyone out. */
function checkAttemptRate(ip, now = Date.now()) {
  let entry = attempts.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + ATTEMPT_WINDOW_MS };
    attempts.set(ip, entry);
  }
  if (entry.count >= ATTEMPT_LIMIT) {
    return { allowed: false, remainingMs: entry.resetAt - now };
  }
  entry.count += 1;
  return { allowed: true, remainingMs: 0 };
}

function clearAttempts(ip) {
  attempts.delete(ip);
}

/** Test seam. */
function reset() {
  sessions.clear();
  attempts.clear();
}

module.exports = {
  ATTEMPT_LIMIT,
  ATTEMPT_WINDOW_MS,
  COOKIE_NAME,
  SESSION_TTL_MS,
  checkAttemptRate,
  clearAttempts,
  clearSessionCookie,
  createSession,
  dropSession,
  enabled,
  hasSession,
  matchesPassword,
  parseCookies,
  reset,
  setSessionCookie,
};
