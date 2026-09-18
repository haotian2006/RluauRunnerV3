const crypto = require("crypto");

const RUN_RATE_LIMIT = 10;
const RUN_RATE_WINDOW_MS = 60_000;
const FORMAT_DEBOUNCE_MS = 500;
const TOOL_DEBOUNCE_MS = 500;
const TOOL_RATE_LIMIT = 20;
const TOOL_RATE_WINDOW_MS = 60_000;
const POLL_RATE_LIMIT = 120;
const POLL_RATE_WINDOW_MS = 60_000;
const SWEEP_INTERVAL_MS = 60_000;

const runRates = new Map();
const pollRates = new Map();
const toolDebounce = new Map();
const toolRates = new Map();

function toolKey(tool, ip) {
  return `${tool}:${ip}`;
}

function checkRunRate(ip) {
  const now = Date.now();
  let entry = runRates.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + RUN_RATE_WINDOW_MS };
    runRates.set(ip, entry);
  }
  if (entry.count >= RUN_RATE_LIMIT) return false;
  entry.count++;
  return true;
}

// One caller may not hold a compiler slot back to back, and may not spend more
// than TOOL_RATE_LIMIT of them a minute. Each tool carries its own budget.
function checkToolDebounce(ip, tool) {
  const now = Date.now();
  const key = toolKey(tool, ip);
  const lastAt = toolDebounce.get(key) || 0;
  if (now - lastAt < TOOL_DEBOUNCE_MS) return false;
  toolDebounce.set(key, now);
  return true;
}

function checkToolRate(ip, tool) {
  const now = Date.now();
  const key = toolKey(tool, ip);
  let entry = toolRates.get(key);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + TOOL_RATE_WINDOW_MS };
    toolRates.set(key, entry);
  }
  if (entry.count >= TOOL_RATE_LIMIT) return false;
  entry.count++;
  return true;
}

function checkFormatDebounce(ip) {
  return checkToolDebounce(ip, "format");
}

// Result polling is meant to be repeated, so the ceiling only exists to stop a
// caller from hammering it faster than a run ever produces new output.
function checkPollRate(ip) {
  const now = Date.now();
  let entry = pollRates.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + POLL_RATE_WINDOW_MS };
    pollRates.set(ip, entry);
  }
  if (entry.count >= POLL_RATE_LIMIT) return false;
  entry.count++;
  return true;
}

/** Salt via IP_SALT. */
function hashIp(ip) {
  return crypto
    .createHash("sha256")
    .update(ip + (process.env.IP_SALT || ""))
    .digest("hex")
    .slice(0, 16);
}

function detectLoops(code) {
  const hasWhile = /\bwhile\b/i.test(code);
  const hasFor = /\bfor\b/i.test(code);
  const hasRepeat = /\brepeat\b/i.test(code);
  if (hasWhile || hasFor || hasRepeat) {
    const loops = [];
    if (hasFor) loops.push("for");
    if (hasWhile) loops.push("while");
    if (hasRepeat) loops.push("repeat");
    return `loops: [${loops.join(", ")}]`;
  }
  return null;
}

function describeSubmission(code) {
  const loopInfo = detectLoops(code);
  return loopInfo
    ? `Code length: ${code.length} chars, ${loopInfo}`
    : `Code length: ${code.length} chars`;
}

const sweep = setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of runRates) {
    if (now > entry.resetAt) runRates.delete(ip);
  }
  for (const [key, lastAt] of toolDebounce) {
    if (now - lastAt > SWEEP_INTERVAL_MS) toolDebounce.delete(key);
  }
  for (const [key, entry] of toolRates) {
    if (now > entry.resetAt) toolRates.delete(key);
  }
  for (const [ip, entry] of pollRates) {
    if (now > entry.resetAt) pollRates.delete(ip);
  }
}, SWEEP_INTERVAL_MS);
sweep.unref();

module.exports = {
  RUN_RATE_LIMIT,
  FORMAT_DEBOUNCE_MS,
  TOOL_DEBOUNCE_MS,
  TOOL_RATE_LIMIT,
  POLL_RATE_LIMIT,
  checkRunRate,
  checkPollRate,
  checkFormatDebounce,
  checkToolDebounce,
  checkToolRate,
  hashIp,
  detectLoops,
  describeSubmission,
};
