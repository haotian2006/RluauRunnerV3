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

/** Learn worker-pool addresses (Roblox publishes no range list); backstop for the user agent check. */
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

/** Roblox stamps a user agent game code can't remove; forging it only lands in the shared bucket. */
function isRobloxOrigin(req) {
  const agent = req?.headers?.["user-agent"];
  if (typeof agent === "string" && ROBLOX_UA.test(agent)) return true;

  const address = normalizeIp(req?.ip);
  if (!address) return false;
  if (workerIps.has(address)) return true;
  const prefix = prefixOf(address);
  return prefix ? workerPrefixes.has(prefix) : false;
}

/** One key for all of Roblox: a worker script with HttpService can loop /run from many Roblox IPs. */
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
