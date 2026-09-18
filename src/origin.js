// Roblox game servers can reach the public web API - a script running on a
// worker has HttpService - so a single script can call /run in a loop and every
// call arrives from a different Roblox datacenter address. Per-IP limits do
// nothing against that, so the whole of Roblox counts as one caller here.

const ROBLOX_UA = /roblox/i;
const ROBLOX_KEY = "roblox";
const MAX_WORKER_IPS = 1000;

/** Addresses that have presented the worker secret, and their /24s. */
const workerIps = new Set();
const workerPrefixes = new Set();

function normalizeIp(ip) {
  if (typeof ip !== "string") return null;
  // Express reports IPv4 through an IPv6 socket as ::ffff:1.2.3.4.
  return ip.startsWith("::ffff:") ? ip.slice(7) : ip;
}

/** The /24 an IPv4 address sits in, or null for anything else. */
function prefixOf(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) {
    return null;
  }
  return `${parts[0]}.${parts[1]}.${parts[2]}.`;
}

function forget(set) {
  if (set.size >= MAX_WORKER_IPS) set.delete(set.values().next().value);
}

/**
 * Remember an address the worker pool authenticated from. Roblox publishes no
 * stable range list, so the pool's own traffic is what teaches us where it
 * lives - a backstop for the case where the user agent is not the giveaway.
 */
function noteWorkerIp(ip) {
  const address = normalizeIp(ip);
  if (!address) return;
  if (!workerIps.has(address)) {
    forget(workerIps);
    workerIps.add(address);
  }
  const prefix = prefixOf(address);
  if (prefix && !workerPrefixes.has(prefix)) {
    forget(workerPrefixes);
    workerPrefixes.add(prefix);
  }
}

/**
 * Roblox stamps its own user agent on HttpService requests and in-game code
 * cannot remove it. Forging it from outside Roblox only moves the caller into
 * the stricter shared bucket, so the heuristic can only fail safe.
 */
function isRobloxOrigin(req) {
  const agent = req?.headers?.["user-agent"];
  if (typeof agent === "string" && ROBLOX_UA.test(agent)) return true;

  const address = normalizeIp(req?.ip);
  if (!address) return false;
  if (workerIps.has(address)) return true;
  const prefix = prefixOf(address);
  return prefix ? workerPrefixes.has(prefix) : false;
}

/**
 * What the rate limiters count against: one key for all of Roblox, the address
 * itself for everyone else.
 */
function limiterKey(req) {
  return isRobloxOrigin(req) ? ROBLOX_KEY : req.ip;
}

/** Test seam. */
function resetWorkerIps() {
  workerIps.clear();
  workerPrefixes.clear();
}

module.exports = {
  ROBLOX_KEY,
  isRobloxOrigin,
  limiterKey,
  noteWorkerIp,
  resetWorkerIps,
};
