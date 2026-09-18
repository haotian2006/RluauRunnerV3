// Counters for the status page. Nothing here is persisted: the process is the
// window, which is why the page shows uptime next to every total. A 24h figure
// on a box that restarted an hour ago means "in that hour", and the page says
// so rather than pretending otherwise.

const os = require("os");

const MAX_EVENTS = 20000;
const LOAD_SAMPLE_MS = 5000;
const MAX_ERRORS = 50;
const HOUR_MS = 60 * 60 * 1000;

const startedAt = Date.now();

/** Ring buffer of { at, kind, name } - one entry per counted thing. */
const events = [];
/** Recent logBot failures, newest last. */
const errors = [];

function push(kind, name, at = Date.now()) {
  if (events.length >= MAX_EVENTS) events.shift();
  events.push({ at, kind, name });
}

function record(kind, name) {
  push(kind, name);
}

function recordError(name, message) {
  if (errors.length >= MAX_ERRORS) errors.shift();
  errors.push({ at: Date.now(), name, message });
  push("error", name);
}

/** Totals for one kind over a window, broken down by name. */
function countBy(kind, windowMs, now = Date.now()) {
  const since = now - windowMs;
  const totals = {};
  let total = 0;
  for (let index = events.length - 1; index >= 0; index--) {
    const event = events[index];
    if (event.at < since) break;
    if (event.kind !== kind) continue;
    totals[event.name] = (totals[event.name] || 0) + 1;
    total += 1;
  }
  return { total, byName: totals };
}

/**
 * Counts per bucket, oldest first, for the activity charts.
 * @returns {{ at: number, count: number }[]}
 */
function histogram(kind, bucketMs, buckets, now = Date.now()) {
  const series = [];
  // The newest bucket ends now, so the last one is partial - that is the point.
  const firstStart = now - bucketMs * buckets;
  for (let index = 0; index < buckets; index++) {
    series.push({ at: firstStart + index * bucketMs, count: 0 });
  }
  for (let index = events.length - 1; index >= 0; index--) {
    const event = events[index];
    if (event.at < firstStart) break;
    if (event.kind !== kind) continue;
    const bucket = Math.min(
      buckets - 1,
      Math.floor((event.at - firstStart) / bucketMs),
    );
    if (bucket >= 0) series[bucket].count += 1;
  }
  return series;
}

function windows(kind, now = Date.now()) {
  return {
    hour: countBy(kind, HOUR_MS, now),
    day: countBy(kind, 24 * HOUR_MS, now),
    twoDay: countBy(kind, 48 * HOUR_MS, now),
  };
}

// CPU percentages are deltas between two readings, so they only exist once the
// sampler has run twice. Until then the page shows them as unknown rather than
// as zero, which would read as an idle box.
let load = { systemPercent: null, processPercent: null };
// Rolling CPU readings for the sparkline: 120 samples at 5s is the last 10min.
const MAX_LOAD_HISTORY = 120;
const loadHistory = [];
let lastCpuTimes = null;
let lastProcessCpu = null;
let lastSampleAt = null;

function totalCpuTimes() {
  let idle = 0;
  let total = 0;
  for (const cpu of os.cpus()) {
    for (const [mode, value] of Object.entries(cpu.times)) {
      total += value;
      if (mode === "idle") idle += value;
    }
  }
  return { idle, total };
}

function sampleLoad(now = Date.now()) {
  const times = totalCpuTimes();
  const processCpu = process.cpuUsage();

  if (lastCpuTimes && lastSampleAt !== null) {
    const totalDelta = times.total - lastCpuTimes.total;
    const idleDelta = times.idle - lastCpuTimes.idle;
    if (totalDelta > 0) {
      load.systemPercent = Math.max(
        0,
        Math.min(100, (1 - idleDelta / totalDelta) * 100),
      );
    }
    const elapsedMs = now - lastSampleAt;
    if (elapsedMs > 0) {
      const usedMs =
        (processCpu.user -
          lastProcessCpu.user +
          (processCpu.system - lastProcessCpu.system)) /
        1000;
      load.processPercent = Math.max(
        0,
        Math.min(100, (usedMs / (elapsedMs * os.cpus().length)) * 100),
      );
    }
  }

  if (load.systemPercent !== null) {
    if (loadHistory.length >= MAX_LOAD_HISTORY) loadHistory.shift();
    loadHistory.push({ at: now, system: load.systemPercent });
  }

  lastCpuTimes = times;
  lastProcessCpu = processCpu;
  lastSampleAt = now;
  return load;
}

function getLoad() {
  return { ...load, cores: os.cpus().length, history: [...loadHistory] };
}

const loadTimer = setInterval(() => sampleLoad(), LOAD_SAMPLE_MS);
loadTimer.unref?.();
sampleLoad();

function uptimeMs(now = Date.now()) {
  return now - startedAt;
}

/**
 * True once the process has been up longer than the window, i.e. the window is
 * actually a full window.
 */
function covers(windowMs, now = Date.now()) {
  return uptimeMs(now) >= windowMs;
}

function recentErrors(limit = 20) {
  return errors.slice(-limit).reverse();
}

/** Test seam. */
function reset() {
  events.length = 0;
  errors.length = 0;
}

module.exports = {
  HOUR_MS,
  MAX_EVENTS,
  countBy,
  covers,
  histogram,
  getLoad,
  sampleLoad,
  recentErrors,
  record,
  recordError,
  reset,
  startedAt,
  uptimeMs,
  windows,
};
