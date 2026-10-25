const crypto = require("crypto");

const CRASH_WINDOW_MS = 2 * 60 * 1000;
const CRASHES_BEFORE_BLOCK = 3;
const BLOCK_DURATION_MS = 45 * 1000;
// Each repeat block doubles the last, capped so it stays a cooldown, not a ban.
// A quiet spell (ESCALATION_RESET_MS) clears the escalation.
const MAX_BLOCK_DURATION_MS = 15 * 60 * 1000;
const ESCALATION_RESET_MS = 30 * 60 * 1000;
const LOCAL_MAX_PER_ACTOR = 10;
const LOCAL_STALE_AFTER_MS = 3 * 1000;
const LOCAL_STALE_LIMIT = 2;
const LOCAL_STALE_BLOCK_MS = 11 * 1000;
const INPUT_WINDOW_MS = 10 * 1000;
// Text inputs are typed by a person; chunks are one file split up, so their
// budget must fit a full upload in one window.
const INPUT_MAX_PER_WINDOW = 40;
const INPUT_CHUNK_MAX_PER_WINDOW = 600;
// Studio-worker runs cost the bot's host, not a Roblox server's HTTP budget, so
// a button-driven game can send several a second.
const STUDIO_INPUT_MAX_PER_WINDOW = 200;

const actorIncidents = new Map();
const localExecutions = new Map();
const localExecutionHealth = new Map();
const localAdmissionBlocks = new Map();
const inputRates = new Map();

function codeHash(source) {
  return crypto.createHash("sha256").update(source).digest("hex");
}

// A timeout is the bot's own kill, not a Lune crash, so only unexpected exits
// earn a strike (the flag stays for reporting).
function isPunishableLuneExit(result) {
  return Boolean(result?.abnormalExit && !result.timedOut);
}

/** Forgive the escalation once the actor has gone quiet for long enough. */
function decayEscalation(entry, now) {
  if (entry.blocks > 0 && now - entry.lastBlockAt > ESCALATION_RESET_MS) {
    entry.blocks = 0;
    entry.lastBlockAt = 0;
  }
}

/** How long the next block lasts: 45s, 90s, 180s ... up to the ceiling. */
function nextBlockDuration(entry) {
  return Math.min(
    BLOCK_DURATION_MS * 2 ** entry.blocks,
    MAX_BLOCK_DURATION_MS,
  );
}

// Dead: no live incidents, no block in force, and no undecayed escalation.
function isEntryDead(entry, now) {
  return (
    entry.incidents.length === 0 &&
    entry.blockedUntil <= now &&
    (entry.blocks === 0 || now - entry.lastBlockAt > ESCALATION_RESET_MS)
  );
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
  decayEscalation(entry, now);
  if (entry.blockedUntil <= now) {
    entry.blockedUntil = 0;
    if (isEntryDead(entry, now)) actorIncidents.delete(actorKey);
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
    entry = { incidents: [], blockedUntil: 0, blocks: 0, lastBlockAt: 0 };
    actorIncidents.set(actorKey, entry);
  }

  pruneIncidents(entry, now);
  decayEscalation(entry, now);
  if (entry.incidents.some((incident) => incident.id === incidentId)) {
    return {
      count: entry.incidents.length,
      blockedUntil: entry.blockedUntil,
      durationMs: 0,
      blocks: entry.blocks,
      duplicate: true,
    };
  }

  entry.incidents.push({
    id: incidentId,
    at: now,
    hashes: [...new Set(hashes)],
  });
  let newlyBlocked = false;
  let durationMs = 0;
  if (entry.incidents.length >= CRASHES_BEFORE_BLOCK) {
    durationMs = nextBlockDuration(entry);
    const nextBlock = now + durationMs;
    newlyBlocked = entry.blockedUntil < nextBlock;
    if (newlyBlocked) {
      entry.blockedUntil = nextBlock;
      entry.blocks += 1;
      entry.lastBlockAt = now;
    } else {
      durationMs = 0;
    }
  }

  return {
    count: entry.incidents.length,
    blockedUntil: entry.blockedUntil,
    durationMs,
    blocks: entry.blocks,
    newlyBlocked,
    duplicate: false,
  };
}

// Counts an actor's active and queued Lune runs; the runner's global cap still
// wins when it is lower.
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

/** Caps how often an actor can queue inputs. Size limits are enforced elsewhere. */
function checkInputRate(actorKey, kind = "input", now = Date.now()) {
  if (!actorKey) return { allowed: true, remainingMs: 0 };

  const limit =
    kind === "chunk"
      ? INPUT_CHUNK_MAX_PER_WINDOW
      : kind === "studio"
        ? STUDIO_INPUT_MAX_PER_WINDOW
        : INPUT_MAX_PER_WINDOW;
  const key = `${actorKey}|${kind}`;
  let entry = inputRates.get(key);
  if (!entry || now >= entry.resetAt) {
    entry = { count: 0, resetAt: now + INPUT_WINDOW_MS };
    inputRates.set(key, entry);
  }

  if (entry.count >= limit) {
    return { allowed: false, remainingMs: entry.resetAt - now, limit };
  }

  entry.count += 1;
  return { allowed: true, remainingMs: 0, limit };
}

/** Actors serving a block right now, worst first, for the status page. */
function listActorBlocks(now = Date.now()) {
  const blocked = [];
  for (const [actorKey, entry] of actorIncidents) {
    if (entry.blockedUntil > now) {
      blocked.push({
        actorKey,
        remainingMs: entry.blockedUntil - now,
        step: entry.blocks,
      });
    }
  }
  return blocked.sort((a, b) => b.remainingMs - a.remainingMs);
}

const sweep = setInterval(() => {
  const now = Date.now();
  for (const [actorKey, entry] of actorIncidents) {
    pruneIncidents(entry, now);
    if (isEntryDead(entry, now)) actorIncidents.delete(actorKey);
  }
  for (const [actorKey, blockedUntil] of localAdmissionBlocks) {
    if (blockedUntil <= now) localAdmissionBlocks.delete(actorKey);
  }
  for (const [key, entry] of inputRates) {
    if (now >= entry.resetAt) inputRates.delete(key);
  }
}, CRASH_WINDOW_MS);
sweep.unref();

module.exports = {
  BLOCK_DURATION_MS,
  CRASHES_BEFORE_BLOCK,
  CRASH_WINDOW_MS,
  ESCALATION_RESET_MS,
  MAX_BLOCK_DURATION_MS,
  LOCAL_MAX_PER_ACTOR,
  LOCAL_STALE_AFTER_MS,
  LOCAL_STALE_BLOCK_MS,
  LOCAL_STALE_LIMIT,
  INPUT_CHUNK_MAX_PER_WINDOW,
  INPUT_MAX_PER_WINDOW,
  INPUT_WINDOW_MS,
  STUDIO_INPUT_MAX_PER_WINDOW,
  acquireLocalExecution,
  checkInputRate,
  codeHash,
  finishLocalExecutionHealth,
  getActorBlock,
  getLocalAdmissionBlock,
  heartbeatLocalExecution,
  isPunishableLuneExit,
  listActorBlocks,
  recordCrash,
  releaseLocalExecution,
  startLocalExecutionHealth,
};
