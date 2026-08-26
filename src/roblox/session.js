const {
  SERVER_CHECK_INTERVAL,
  SERVER_CREATION_COOL_DOWN,
  SERVER_PING_TIMEOUT,
  SERVER_RECOVERY_GRACE_MS,
  SERVER_RUN_TIME_MAX,
  SERVER_TIME_OUT,
  ENABLE_LOCAL_EXEC,
  botSrcEncoded,
} = require("../config");
const { decodeZstd } = require("../chunks");
const { recordCrash } = require("../abuse");
const { log, logBot } = require("../log");
const { getMaxWorkers, getProfiles } = require("../profiles");
const {
  ExecuteTasks,
  RobloxServers,
  SECRET_TOKEN,
  getUnfinishedTasksForServer,
  state,
  takeUnfinishedTasksForServer,
  unregisterRobloxServer,
} = require("../state");
const { wait } = require("../util");
const { closeSession, getSession } = require("../core/sessions");
const { tryRunLocally } = require("../local/dispatch");

function bootstrapScript() {
  return `local EncodingService = game:GetService("EncodingService")

  local str = [[${botSrcEncoded}]]
  local decoded = EncodingService:Base64Decode(buffer.fromstring(str))
  decoded = EncodingService:DecompressBuffer(decoded,Enum.CompressionAlgorithm.Zstd)
  local Instances =  game:GetService("SerializationService"):DeserializeInstancesAsync(decoded)
  local module = Instances[1]

     require(module).start("${state.CallbackUrl}", "${SECRET_TOKEN}")
`;
}

async function startRoblox(profile) {
  state.LastServerCreation = Date.now();
  const reservation = { profileName: profile.name, createdAt: Date.now() };
  state.PendingRobloxStarts.push(reservation);

  const cancelReservation = () => {
    const index = state.PendingRobloxStarts.indexOf(reservation);
    if (index !== -1) state.PendingRobloxStarts.splice(index, 1);
  };

  let res;
  try {
    res = await fetch(profile.executeUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": profile.apiKey,
      },
      body: JSON.stringify({
        script: bootstrapScript(),
        timeout: SERVER_TIME_OUT,
      }),
      signal: AbortSignal.timeout(30_000),
    });
  } catch (err) {
    console.log(
      `Failed to reach Roblox for profile ${profile.name}:`,
      err.message,
    );
    log(
      "0",
      "BOT",
      "Failed to start Roblox",
      `${profile.name}: ${err.message}`,
    );
    cancelReservation();
    return false;
  }

  if (!res.ok) {
    console.log(
      `Failed to start Roblox with profile ${profile.name}: `,
      res.statusText,
    );
    log(
      "0",
      "BOT",
      "Failed to start Roblox",
      `${profile.name}: ${res.statusText}`,
    );
    cancelReservation();
    return false;
  }

  state.SERVERS_CREATED++;
  setTimeout(() => {
    state.SERVERS_CREATED--;
  }, 90000);
  return true;
}

/**
 * How long to wait between session creations. Backs off when many sessions
 * have been created recently.
 */
function creationDebounce() {
  if (state.SERVERS_CREATED <= 2) {
    return SERVER_CREATION_COOL_DOWN / 1.5;
  }
  if (state.SERVERS_CREATED >= 5) {
    return SERVER_CREATION_COOL_DOWN * 1.5;
  }
  return SERVER_CREATION_COOL_DOWN;
}

let nextProfileIndex = 0;

function profileAttemptOrder(profiles, startIndex) {
  return profiles.map((profile, offset) => {
    const index = (startIndex + offset) % profiles.length;
    return { profile: profiles[index], index };
  });
}

async function startAnyProfile() {
  const profiles = getProfiles();
  if (profiles.length === 0) {
    logBot("Roblox Server", "No profiles configured; cannot start a session.");
    return false;
  }

  const startIndex = nextProfileIndex % profiles.length;
  const candidates = profileAttemptOrder(profiles, startIndex);

  for (const [attempt, candidate] of candidates.entries()) {
    const { profile, index } = candidate;
    const started = await startRoblox(profile);
    if (started) {
      nextProfileIndex = (index + 1) % profiles.length;
      return true;
    }
    if (attempt < candidates.length - 1) {
      logBot(
        "Roblox Server",
        `Profile ${profile.name} failed, trying the next one...`,
      );
    }
  }

  nextProfileIndex = (startIndex + 1) % profiles.length;
  return false;
}

async function failTask(task, message) {
  const session = getSession(task.token);
  if (!session) return;

  let link = null;
  try {
    link = session.responder.link?.();
  } catch {}

  try {
    await session.responder.fail(new Error(message), link);
  } finally {
    closeSession(task.token);
  }
}

async function failPendingTasks() {
  const pending = Object.entries(ExecuteTasks);
  const failures = [];

  for (const [taskId, task] of pending) {
    if (ExecuteTasks[taskId] !== task) continue;
    delete ExecuteTasks[taskId];
    failures.push(failTask(task, "Failed to start."));
  }

  await Promise.allSettled(failures);
}

function reapRobloxServer(serverId) {
  const tasks = takeUnfinishedTasksForServer(serverId);
  unregisterRobloxServer(serverId);

  return Promise.allSettled(
    tasks.map((task) => failTask(task, "Roblox server stopped responding.")),
  );
}

function luneActorKey(actorKey) {
  return typeof actorKey === "string"
    ? actorKey.replace(/:roblox$/, ":lune")
    : actorKey;
}

async function fallbackPendingTasksToLune() {
  const pending = Object.entries(ExecuteTasks);
  const runs = [];

  for (const [taskId, task] of pending) {
    if (ExecuteTasks[taskId] !== task) continue;
    delete ExecuteTasks[taskId];

    let source;
    try {
      source = decodeZstd(task.content).toString("utf8");
    } catch (error) {
      const session = getSession(task.token);
      if (session) {
        try {
          await session.responder.fail(error, session.responder.link?.());
        } catch {}
      }
      closeSession(task.token);
      continue;
    }

    const actorKey = luneActorKey(task.actorKey);
    runs.push(
      tryRunLocally(source, task.token, {
        actorKey,
        allowCodegen: !task.isWeb,
        selection: { runtime: "lune", classification: null },
      }),
    );
  }

  if (runs.length) {
    logBot(
      "Roblox Fallback",
      `All profiles failed; moved ${runs.length} queued task(s) to Lune.`,
    );
  }
  return Promise.allSettled(runs);
}

function recordServerOutage(serverId, lastPing) {
  const unfinished = getUnfinishedTasksForServer(serverId);
  const actors = new Map();

  for (const task of unfinished) {
    if (!task?.actorKey) continue;
    let hashes = actors.get(task.actorKey);
    if (!hashes) {
      hashes = new Set();
      actors.set(task.actorKey, hashes);
    }
    if (task.codeHash) hashes.add(task.codeHash);
  }

  const incidentId = `roblox:${serverId}:${lastPing}`;
  for (const [actorKey, hashes] of actors) {
    const result = recordCrash(actorKey, incidentId, [...hashes]);
    logBot(
      "Roblox Crash Attribution",
      `${actorKey}: ${result.count} crash(es) in window` +
        (result.newlyBlocked ? ", blocked for 45s" : ""),
    );
  }

  return { actors: actors.size, unfinished: unfinished.length };
}

function needsAdditionalWorker(workers, queuedTasks, pendingWorkers) {
  const responsiveWorkers = workers.filter(
    (server) => server.healthy && !server.retiring,
  ).length;
  return queuedTasks > responsiveWorkers + pendingWorkers;
}

async function checkRobloxServer() {
  while (true) {
    const now = Date.now();

    state.PendingRobloxStarts = state.PendingRobloxStarts.filter(
      (entry) => now - entry.createdAt <= 90_000,
    );

    for (const server of Object.values(RobloxServers)) {
      if (
        !server.retiring &&
        server.activeTaskIds.size === 0 &&
        now - server.startedAt > SERVER_RUN_TIME_MAX
      ) {
        server.retiring = true;
      }

      if (now - server.lastPing <= SERVER_PING_TIMEOUT) continue;

      if (server.retiring) {
        void reapRobloxServer(server.serverId);
        continue;
      }

      if (server.healthy && !server.outageRecorded) {
        server.healthy = false;
        server.unhealthySince = now;
        server.outageRecorded = true;
        const attributed = recordServerOutage(server.serverId, server.lastPing);
        logBot(
          "Roblox Server Outage",
          `${server.serverId}: ${attributed.unfinished} unfinished task(s), ` +
            `${attributed.actors} actor(s) attributed`,
        );
      }

      if (
        now - (server.unhealthySince || server.lastPing) >=
        SERVER_RECOVERY_GRACE_MS
      ) {
        void reapRobloxServer(server.serverId);
      }
    }

    const workers = Object.values(RobloxServers);
    const queuedTasks = Object.keys(ExecuteTasks).length;
    const pendingWorkers = state.PendingRobloxStarts.length;
    const lastCreationDebounce =
      now - state.LastServerCreation > creationDebounce();
    const maxWorkers = getMaxWorkers();
    const belowWorkerCap = workers.length + pendingWorkers < maxWorkers;
    const needsWorker = needsAdditionalWorker(
      workers,
      queuedTasks,
      pendingWorkers,
    );

    if (needsWorker && belowWorkerCap && lastCreationDebounce) {
      console.log("Starting new Roblox server...");
      logBot(
        "Roblox Server",
        `Starting worker ${workers.length + pendingWorkers + 1}/${maxWorkers}...`,
      );

      if (!(await startAnyProfile())) {
        if (workers.length === 0 && state.PendingRobloxStarts.length === 0) {
          if (ENABLE_LOCAL_EXEC) {
            void fallbackPendingTasksToLune();
          } else {
            await failPendingTasks();
          }
        }
      }
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

module.exports = {
  checkRobloxServer,
  failPendingTasks,
  fallbackPendingTasksToLune,
  luneActorKey,
  needsAdditionalWorker,
  profileAttemptOrder,
  reapRobloxServer,
  recordServerOutage,
};
