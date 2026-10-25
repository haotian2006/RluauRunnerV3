const {
  SERVER_CHECK_INTERVAL,
  SERVER_CREATION_COOL_DOWN,
  SERVER_PING_TIMEOUT,
  SERVER_RECOVERY_GRACE_MS,
  SERVER_RUN_TIME_MAX,
  SERVER_TIME_OUT,
  STUDIO_SESSION_MS,
  WORKER_STREAM_GRACE_MS,
  WORKER_STREAM_PING_TIMEOUT,
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
  canServeMode,
  getUnfinishedTasksForServer,
  requeueUnstartedTasksForServer,
  state,
  takeUnfinishedTasksForServer,
  taskMode,
  unregisterRobloxServer,
} = require("../state");
const { wait } = require("../util");
const { closeSession, getSession } = require("../core/sessions");
const { tryRunLocally } = require("../local/dispatch");
const { notifyWorkers } = require("../workerEvents");

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

/** Wait between session creations; backs off when many were created recently. */
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
  if (!session) {
    // No session to reply to, so the embed stays stuck (usually on pending); log it.
    logBot(
      "Task Failure Dropped",
      `"${message}" for token ${task.token} had no session; its embed is now stuck`,
    );
    return;
  }
  logBot("Task Failed", `${task.token}: ${message}`);

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

const SESSION_ENDED = "Session ended.";

function reapRobloxServer(
  serverId,
  message = "Roblox server stopped responding.",
) {
  const tasks = takeUnfinishedTasksForServer(serverId);
  unregisterRobloxServer(serverId);
  if (tasks.length) {
    logBot(
      "Roblox Server Reaped",
      `${serverId}: ${tasks.length} unfinished task(s) failed`,
    );
  }

  return Promise.allSettled(tasks.map((task) => failTask(task, message)));
}

// A worker whose /workerEvents stream closed for good is gone. Unstarted tasks
// are requeued; only actors with runs going when a session died early get a strike.
function reapLostWorker(serverId) {
  const server = RobloxServers[serverId];
  if (!server) return Promise.resolve([]);
  const { requeued, exhausted } = requeueUnstartedTasksForServer(serverId);
  if (server.retiring) {
    logBot(
      "Worker Session Ended",
      `${serverId}: ${requeued} unstarted task(s) requeued`,
    );
  } else {
    const attributed = recordServerOutage(serverId);
    logBot(
      "Worker Lost",
      `${serverId}: event stream closed; ${requeued} unstarted task(s) requeued, ` +
        `${attributed.unfinished} running, ${attributed.actors} actor(s) attributed`,
    );
  }
  return Promise.allSettled([
    ...exhausted.map((task) => failTask(task, "Lost handoff to Roblox.")),
    reapRobloxServer(serverId, server.retiring ? SESSION_ENDED : undefined),
  ]);
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
    // tryRunLocally returns false when Lune is at capacity ("queue it for
    // Roblox"). The task is already out of ExecuteTasks, so ignoring that loses it.
    runs.push(
      tryRunLocally(source, task.token, {
        actorKey,
        allowCodegen: true,
        selection: { runtime: "lune", classification: null },
      })
        .then((handled) => {
          if (handled) return;
          if (!getSession(task.token)) {
            logBot(
              "Roblox Fallback",
              `Lune declined task ${taskId} and its session is gone; dropping it`,
            );
            return;
          }
          ExecuteTasks[taskId] = task;
          notifyWorkers("task");
          logBot(
            "Roblox Fallback",
            `Lune was busy, requeued task ${taskId} for Roblox`,
          );
        })
        .catch(async (error) => {
          logBot(
            "Roblox Fallback",
            `Lune run for task ${taskId} threw: ${error.message}`,
          );
          await failTask(task, `Fallback to Lune failed: ${error.message}`);
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

// One strike per actor per server: repeated missed heartbeats on one server are
// one outage, not a new crash each time.
function recordServerOutage(serverId) {
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

  const incidentId = `roblox:${serverId}`;
  for (const [actorKey, hashes] of actors) {
    const result = recordCrash(actorKey, incidentId, [...hashes]);
    logBot(
      "Roblox Crash Attribution",
      `${actorKey}: ${result.count} crash(es) in window` +
        (result.newlyBlocked
          ? `, blocked for ${Math.round(result.durationMs / 1000)}s (block #${result.blocks})`
          : ""),
    );
  }

  return { actors: actors.size, unfinished: unfinished.length };
}

// `queued` is a count, or the tasks themselves so --!nosandbox work (which
// never shares a server with sandboxed work) is sized separately.
function needsAdditionalWorker(workers, queued, pendingWorkers) {
  const responsive = workers.filter(
    (server) => server.healthy && !server.retiring,
  );
  if (typeof queued === "number") {
    return queued > responsive.length + pendingWorkers;
  }
  for (const mode of ["sandbox", "nosandbox"]) {
    const waiting = queued.filter((task) => taskMode(task) === mode).length;
    if (waiting === 0) continue;
    const able = responsive.filter((server) => canServeMode(server, mode));
    // A Studio worker takes any number of runs, so Open Cloud starts only when none is up.
    if (able.some((server) => server.kind === "studio")) continue;
    if (waiting > able.length + pendingWorkers) return true;
  }
  return false;
}

// One health-check pass: retires idle servers, reaps dead ones, flags silent ones.
function checkServer(server, now = Date.now()) {
  if (
    !server.retiring &&
    server.activeTaskIds.size === 0 &&
    now - server.startedAt > SERVER_RUN_TIME_MAX
  ) {
    server.retiring = true;
  }

  // A worker that polls or pings after its stream closed is still alive; one
  // that doesn't within the grace period is gone. Until then, wait.
  if (server.streamLostAt) {
    if (server.lastPing > server.streamLostAt) {
      server.streamLostAt = null;
    } else {
      if (now - server.streamLostAt >= WORKER_STREAM_GRACE_MS) {
        void reapLostWorker(server.serverId);
      }
      return;
    }
  }

  // A draining Studio session stops polling but runs its tasks until it
  // ends itself; its stream closing, or that time passing, reaps it.
  if (server.kind === "studio" && server.retiring && server.streams > 0) {
    if (server.activeTaskIds.size === 0) {
      void reapRobloxServer(server.serverId);
    } else if (
      now - server.startedAt >=
      STUDIO_SESSION_MS + WORKER_STREAM_GRACE_MS
    ) {
      void reapRobloxServer(server.serverId, SESSION_ENDED);
    }
    return;
  }

  const pingTimeout =
    server.streams > 0 ? WORKER_STREAM_PING_TIMEOUT : SERVER_PING_TIMEOUT;
  if (now - server.lastPing <= pingTimeout) return;

  // A draining session pings every 2 s; silence means it ended or was cut off.
  if (server.retiring) {
    void reapRobloxServer(
      server.serverId,
      server.kind === "studio" ? SESSION_ENDED : undefined,
    );
    return;
  }

  if (server.healthy && !server.outageRecorded) {
    server.healthy = false;
    server.unhealthySince = now;
    server.outageRecorded = true;
  }

  // A busy script can delay heartbeats, so only a server silent for the whole
  // grace period counts as a crash.
  if (
    now - (server.unhealthySince || server.lastPing) >=
    SERVER_RECOVERY_GRACE_MS
  ) {
    if (!server.crashRecorded) {
      server.crashRecorded = true;
      const attributed = recordServerOutage(server.serverId);
      logBot(
        "Roblox Server Outage",
        `${server.serverId}: ${attributed.unfinished} unfinished task(s), ` +
          `${attributed.actors} actor(s) attributed`,
      );
    }
    void reapRobloxServer(server.serverId);
  }
}

async function checkRobloxServer() {
  while (true) {
    const now = Date.now();

    const abandonedStarts = state.PendingRobloxStarts.filter(
      (entry) => now - entry.createdAt > 90_000,
    );
    state.PendingRobloxStarts = state.PendingRobloxStarts.filter(
      (entry) => now - entry.createdAt <= 90_000,
    );
    if (abandonedStarts.length) {
      logBot(
        "Roblox Server",
        `${abandonedStarts.length} start(s) accepted but never registered: ` +
          abandonedStarts.map((entry) => entry.profileName).join(", "),
      );
    }

    for (const server of Object.values(RobloxServers)) checkServer(server, now);

    const workers = Object.values(RobloxServers);
    const pendingWorkers = state.PendingRobloxStarts.length;
    const lastCreationDebounce =
      now - state.LastServerCreation > creationDebounce();
    const maxWorkers = getMaxWorkers();
    // Studio workers are not Open Cloud servers, so they leave the cap alone.
    const cloudWorkers = workers.filter((server) => server.kind !== "studio");
    const belowWorkerCap = cloudWorkers.length + pendingWorkers < maxWorkers;
    const needsWorker = needsAdditionalWorker(
      workers,
      Object.values(ExecuteTasks),
      pendingWorkers,
    );

    let startFailed = false;
    if (needsWorker && belowWorkerCap && lastCreationDebounce) {
      console.log("Starting new Roblox server...");
      logBot(
        "Roblox Server",
        `Starting worker ${cloudWorkers.length + pendingWorkers + 1}/${maxWorkers}...`,
      );
      startFailed = !(await startAnyProfile());
    }

    // A failed start or an expired reservation (launch accepted, no worker)
    // means no worker is coming; a debounce gap doesn't. Silent or draining
    // servers take no tasks, so they don't hold the queue back.
    if (
      (startFailed || abandonedStarts.length > 0) &&
      Object.keys(ExecuteTasks).length > 0 &&
      !Object.values(RobloxServers).some(
        (server) => server.healthy && !server.retiring,
      ) &&
      state.PendingRobloxStarts.length === 0
    ) {
      logBot(
        "Roblox Server",
        `No worker and no pending start for ${Object.keys(ExecuteTasks).length} queued task(s)`,
      );
      if (ENABLE_LOCAL_EXEC) {
        void fallbackPendingTasksToLune();
      } else {
        await failPendingTasks();
      }
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

module.exports = {
  checkRobloxServer,
  checkServer,
  failPendingTasks,
  fallbackPendingTasksToLune,
  luneActorKey,
  needsAdditionalWorker,
  profileAttemptOrder,
  reapLostWorker,
  reapRobloxServer,
  recordServerOutage,
};
