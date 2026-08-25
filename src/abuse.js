const crypto = require("crypto");

const CRASH_WINDOW_MS = 2 * 60 * 1000;
const CRASHES_BEFORE_BLOCK = 3;
const BLOCK_DURATION_MS = 45 * 1000;
const LOCAL_MAX_PER_ACTOR = 10;
const LOCAL_STALE_AFTER_MS = 3 * 1000;
const LOCAL_STALE_LIMIT = 2;
const LOCAL_STALE_BLOCK_MS = 11 * 1000;

const actorIncidents = new Map();
const localExecutions = new Map();
const localExecutionHealth = new Map();
const localAdmissionBlocks = new Map();

function codeHash(source) {
  return crypto.createHash("sha256").update(source).digest("hex");
}

// A timeout is an intentional kill by the bot's own time limit, not a Lune
// crash. Keep the flag for reporting, but only unexpected process exits earn a
// crash strike.
function isPunishableLuneExit(result) {
  return Boolean(result?.abnormalExit && !result.timedOut);
}

function pruneIncidents(entry, now) {
  entry.incidents = entry.incidents.filter(
    (incident) => now - incident.at < CRASH_WINDOW_MS,
  );
}

function getActorBlock(actorKey, now = Date.now()) {
  if (!actorKey) return null;
  const entry = actorIncidents.get(actorKey);
  if (!entry) return null;

  pruneIncidents(entry, now);
  if (entry.blockedUntil <= now) {
    entry.blockedUntil = 0;
    if (entry.incidents.length === 0) actorIncidents.delete(actorKey);
    return null;
  }

  return {
    blockedUntil: entry.blockedUntil,
    remainingMs: entry.blockedUntil - now,
  };
}

/** Record at most one strike for an actor for a particular server outage. */
function recordCrash(actorKey, incidentId, hashes = [], now = Date.now()) {
  if (!actorKey || !incidentId) return null;

  let entry = actorIncidents.get(actorKey);
  if (!entry) {
    entry = { incidents: [], blockedUntil: 0 };
    actorIncidents.set(actorKey, entry);
  }

  pruneIncidents(entry, now);
  if (entry.incidents.some((incident) => incident.id === incidentId)) {
    return {
      count: entry.incidents.length,
      blockedUntil: entry.blockedUntil,
      duplicate: true,
    };
  }

  entry.incidents.push({
    id: incidentId,
    at: now,
    hashes: [...new Set(hashes)],
  });
  let newlyBlocked = false;
  if (entry.incidents.length >= CRASHES_BEFORE_BLOCK) {
    const nextBlock = now + BLOCK_DURATION_MS;
    newlyBlocked = entry.blockedUntil < nextBlock;
    entry.blockedUntil = Math.max(entry.blockedUntil, nextBlock);
  }

  return {
    count: entry.incidents.length,
    blockedUntil: entry.blockedUntil,
    newlyBlocked,
    duplicate: false,
  };
}

// Counts active and globally queued Lune runs. The runner's separate global
// cap remains authoritative when it is configured lower than this per-actor cap.
function acquireLocalExecution(actorKey) {
  if (!actorKey) return true;
  const count = localExecutions.get(actorKey) || 0;
  if (count >= LOCAL_MAX_PER_ACTOR) return false;
  localExecutions.set(actorKey, count + 1);
  return true;
}

function releaseLocalExecution(actorKey) {
  if (!actorKey) return;
  const count = localExecutions.get(actorKey) || 0;
  if (count <= 1) {
    localExecutions.delete(actorKey);
  } else {
    localExecutions.set(actorKey, count - 1);
  }
}

function startLocalExecutionHealth(actorKey, executionId, now = Date.now()) {
  if (!actorKey || !executionId) return;
  let executions = localExecutionHealth.get(actorKey);
  if (!executions) {
    executions = new Map();
    localExecutionHealth.set(actorKey, executions);
  }
  const execution = { lastHeartbeatAt: now, staleTimer: null };
  executions.set(executionId, execution);
  armLocalStaleTimer(actorKey, executionId, execution);
}

function heartbeatLocalExecution(actorKey, executionId, now = Date.now()) {
  const execution = localExecutionHealth.get(actorKey)?.get(executionId);
  if (!execution) return;
  execution.lastHeartbeatAt = now;
  armLocalStaleTimer(actorKey, executionId, execution);
}

function finishLocalExecutionHealth(actorKey, executionId) {
  const executions = localExecutionHealth.get(actorKey);
  if (!executions) return;
  const execution = executions.get(executionId);
  if (execution?.staleTimer) clearTimeout(execution.staleTimer);
  executions.delete(executionId);
  if (executions.size === 0) localExecutionHealth.delete(actorKey);
}

function armLocalStaleTimer(actorKey, executionId, execution) {
  if (execution.staleTimer) clearTimeout(execution.staleTimer);
  execution.staleTimer = setTimeout(() => {
    const current = localExecutionHealth.get(actorKey)?.get(executionId);
    if (current !== execution) return;
    getLocalAdmissionBlock(actorKey);
  }, LOCAL_STALE_AFTER_MS);
  execution.staleTimer.unref?.();
}

function getLocalAdmissionBlock(actorKey, now = Date.now()) {
  if (!actorKey) return null;

  const existingBlock = localAdmissionBlocks.get(actorKey) || 0;
  if (existingBlock > now) {
    return {
      blockedUntil: existingBlock,
      remainingMs: existingBlock - now,
    };
  }
  if (existingBlock) localAdmissionBlocks.delete(actorKey);

  const executions = localExecutionHealth.get(actorKey);
  if (!executions) return null;

  let staleCount = 0;
  for (const execution of executions.values()) {
    if (now - execution.lastHeartbeatAt >= LOCAL_STALE_AFTER_MS) {
      staleCount += 1;
      if (staleCount >= LOCAL_STALE_LIMIT) break;
    }
  }
  if (staleCount < LOCAL_STALE_LIMIT) return null;

  const blockedUntil = now + LOCAL_STALE_BLOCK_MS;
  localAdmissionBlocks.set(actorKey, blockedUntil);
  return {
    blockedUntil,
    remainingMs: LOCAL_STALE_BLOCK_MS,
  };
}

const sweep = setInterval(() => {
  const now = Date.now();
  for (const [actorKey, entry] of actorIncidents) {
    pruneIncidents(entry, now);
    if (entry.incidents.length === 0 && entry.blockedUntil <= now) {
      actorIncidents.delete(actorKey);
    }
  }
  for (const [actorKey, blockedUntil] of localAdmissionBlocks) {
    if (blockedUntil <= now) localAdmissionBlocks.delete(actorKey);
  }
}, CRASH_WINDOW_MS);
sweep.unref();

module.exports = {
  BLOCK_DURATION_MS,
  CRASHES_BEFORE_BLOCK,
  CRASH_WINDOW_MS,
  LOCAL_MAX_PER_ACTOR,
  LOCAL_STALE_AFTER_MS,
  LOCAL_STALE_BLOCK_MS,
  LOCAL_STALE_LIMIT,
  acquireLocalExecution,
  codeHash,
  finishLocalExecutionHealth,
  getActorBlock,
  getLocalAdmissionBlock,
  heartbeatLocalExecution,
  isPunishableLuneExit,
  recordCrash,
  releaseLocalExecution,
  startLocalExecutionHealth,
};
