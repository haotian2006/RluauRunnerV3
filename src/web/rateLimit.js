const crypto = require("crypto");

const RUN_RATE_LIMIT = 30;
const RUN_RATE_WINDOW_MS = 60_000;
const FORMAT_DEBOUNCE_MS = 500;
const SWEEP_INTERVAL_MS = 60_000;

const runRates = new Map();
const formatDebounce = new Map();

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

function checkFormatDebounce(ip) {
  const now = Date.now();
  const lastAt = formatDebounce.get(ip) || 0;
  if (now - lastAt < FORMAT_DEBOUNCE_MS) return false;
  formatDebounce.set(ip, now);
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
  for (const [ip, lastAt] of formatDebounce) {
    if (now - lastAt > SWEEP_INTERVAL_MS) formatDebounce.delete(ip);
  }
}, SWEEP_INTERVAL_MS);
sweep.unref();

module.exports = {
  RUN_RATE_LIMIT,
  FORMAT_DEBOUNCE_MS,
  checkRunRate,
  checkFormatDebounce,
  hashIp,
  detectLoops,
  describeSubmission,
};
