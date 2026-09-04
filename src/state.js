const crypto = require("crypto");
const { closeSession, getSession } = require("./core/sessions");
const { logBot } = require("./log");

const state = {
  CallbackUrl: "",

  // Legacy single-server fields are kept for compatibility with older tests
  // and integrations. New scheduling uses RobloxServers below.
  RunningServer: "",
  RunningServerTime: 0,
  LastServerPing: 0,
  RunningServerHealthy: false,
  LastServerCreation: 0,
  PendingRobloxStarts: [],

  SERVERS_CREATED: 0,
  SERVER_NUMBERS: 0,
};

const SECRET_TOKEN = crypto.randomBytes(32).toString("hex");

const ExecuteTasks = {};

const CompilingTasks = {};

const Inputs = {};

const ScriptButtonCallbacks = new Map();

const docCodeStore = {};

const DispatchedTasks = {};

const ActiveRobloxTasks = {};

const RobloxServers = {};

/**
 * Tasks already requeued once, so a lost handoff is retried exactly one time.
 *
 * Keyed by the task object rather than its uuid, and weak on purpose: a task
 * is abandoned down several paths (the retry timer giving up, the six-minute
 * expiry, /stopall, failPendingTasks) and only one of them used to clean up.
 * Holding the object weakly means the entry disappears with the task itself,
 * so no path can leak. Do not swap this for a Set of uuids.
 */
const retriedTasks = new WeakSet();

const DISPATCH_RETRY_MS = 60 * 1000;

function registerRobloxServer(serverId, now = Date.now()) {
  if (!serverId) return null;
  const existing = RobloxServers[serverId];
  if (existing) return existing;
  const server = {
    serverId,
    startedAt: now,
    lastPing: now,
    healthy: false,
    unhealthySince: now,
    outageRecorded: false,
    retiring: false,
    activeTaskIds: new Set(),
  };
  RobloxServers[serverId] = server;
  return server;
}

function touchRobloxServer(serverId, now = Date.now()) {
  const server = RobloxServers[serverId];
  if (!server) return null;
  server.lastPing = now;
  server.healthy = true;
  server.unhealthySince = null;
  server.outageRecorded = false;
  return server;
}

function retireRobloxServer(serverId) {
  const server = RobloxServers[serverId];
  if (!server) return null;
  server.retiring = true;
  return server;
}

function unregisterRobloxServer(serverId) {
  const server = RobloxServers[serverId];
  delete RobloxServers[serverId];
  return server || null;
}

function releaseServerTask(serverId, uuid) {
  const server = RobloxServers[serverId];
  server?.activeTaskIds.delete(uuid);
}

function dispatchTask(uuid, serverId = state.RunningServer) {
  const task = ExecuteTasks[uuid];
  if (!task) return null;
  delete ExecuteTasks[uuid];

  const previous = DispatchedTasks[uuid];
  if (previous) clearTimeout(previous.timer);

  const timer = setTimeout(() => {
    const entry = DispatchedTasks[uuid];
    delete DispatchedTasks[uuid];
    releaseServerTask(entry?.serverId, uuid);

    logBot(
      "Roblox Handoff",
      `task ${uuid} was claimed by ${entry?.serverId} but never responded ` +
        `in ${DISPATCH_RETRY_MS / 1000}s`,
    );

    if (retriedTasks.has(task)) {
      const session = getSession(task.token);
      if (session) {
        let link = null;
        try {
          link = session.responder.link?.();
        } catch {}
        Promise.resolve(
          session.responder.fail(new Error("Lost handoff to Roblox."), link),
        )
          .catch(() => {})
          .finally(() => closeSession(task.token));
      }
      return;
    }

    retriedTasks.add(task);
    ExecuteTasks[uuid] = task;
    logBot("Roblox Handoff", `task ${uuid} requeued for another worker`);
  }, DISPATCH_RETRY_MS);

  DispatchedTasks[uuid] = {
    task,
    timer,
    serverId,
    dispatchedAt: Date.now(),
  };
  logBot("Roblox Handoff", `task ${uuid} claimed by ${serverId}`);
  return DispatchedTasks[uuid];
}

function reserveNextTask(serverId) {
  const server = RobloxServers[serverId];
  if (!server || server.retiring) return null;
  const uuid = Object.keys(ExecuteTasks)[0];
  if (!uuid || !dispatchTask(uuid, serverId)) return null;
  server.activeTaskIds.add(uuid);
  return uuid;
}

function getDispatchedTask(uuid) {
  return DispatchedTasks[uuid]?.task || null;
}

function settleTasksForToken(token, finished = true) {
  for (const uuid of Object.keys(DispatchedTasks)) {
    const entry = DispatchedTasks[uuid];
    if (entry?.task?.token === token) {
      clearTimeout(entry.timer);
      delete DispatchedTasks[uuid];
      if (!finished) {
        // The retry timer is dropped here. From now on only a server reap can
        // recover this task, so record where it went.
        ActiveRobloxTasks[uuid] = {
          ...entry,
          timer: null,
          startedAt: Date.now(),
        };
        logBot(
          "Roblox Handoff",
          `task ${uuid} is running on ${entry.serverId}; retry timer cleared`,
        );
      } else {
        releaseServerTask(entry.serverId, uuid);
      }
    }
  }

  if (finished) {
    for (const uuid of Object.keys(ActiveRobloxTasks)) {
      if (ActiveRobloxTasks[uuid]?.task?.token === token) {
        releaseServerTask(ActiveRobloxTasks[uuid].serverId, uuid);
        delete ActiveRobloxTasks[uuid];
      }
    }
  }
}

function unfinishedTasksForServer(serverId, removeActive) {
  const tasks = [];

  for (const [uuid, entry] of Object.entries(DispatchedTasks)) {
    if (entry?.serverId !== serverId) continue;
    tasks.push(entry.task);
    if (removeActive) {
      clearTimeout(entry.timer);
      delete DispatchedTasks[uuid];
    }
  }

  for (const [uuid, entry] of Object.entries(ActiveRobloxTasks)) {
    if (entry?.serverId !== serverId) continue;
    tasks.push(entry.task);
    if (removeActive) delete ActiveRobloxTasks[uuid];
  }

  return tasks;
}

function getUnfinishedTasksForServer(serverId) {
  return unfinishedTasksForServer(serverId, false);
}

function takeUnfinishedTasksForServer(serverId) {
  return unfinishedTasksForServer(serverId, true);
}

module.exports = {
  state,
  SECRET_TOKEN,
  ExecuteTasks,
  CompilingTasks,
  Inputs,
  ScriptButtonCallbacks,
  docCodeStore,
  ActiveRobloxTasks,
  DispatchedTasks,
  RobloxServers,
  registerRobloxServer,
  touchRobloxServer,
  retireRobloxServer,
  unregisterRobloxServer,
  dispatchTask,
  reserveNextTask,
  getDispatchedTask,
  settleTasksForToken,
  getUnfinishedTasksForServer,
  takeUnfinishedTasksForServer,
};
