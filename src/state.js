const crypto = require("crypto");
const { closeSession, getSession } = require("./core/sessions");
const { logBot } = require("./log");
const { notifyWorkers } = require("./workerEvents");

const state = {
  CallbackUrl: "",

  // Legacy single-server fields for old tests; scheduling uses RobloxServers.
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

// Roblox holds /getInputs open until something is queued; these wake it.
const inputWaiters = new Set();

function putInput(entry) {
  Inputs[entry.uid] = entry;
  for (const wake of inputWaiters) wake();
  inputWaiters.clear();
  notifyWorkers("input");
}

/** Resolves on the next putInput, after `ms`, or when `signal` aborts. */
function waitForInput(ms, signal) {
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      inputWaiters.delete(done);
      signal?.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    inputWaiters.add(done);
    signal?.addEventListener("abort", done);
  });
}

const ScriptButtonCallbacks = new Map();

const docCodeStore = {};
const docPreviewStore = {};

const DispatchedTasks = {};

const ActiveRobloxTasks = {};

const RobloxServers = {};

/** Tasks requeued once. Weak and keyed by task object so every drop path frees it. */
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
    // Set by its first task; --!nosandbox runs never share a server with sandboxed ones.
    mode: null,
    // "studio" for a headless Studio worker on this host, else an Open Cloud server.
    kind: "cloud",
    // Open GET /workerEvents streams, and when the last one closed.
    streams: 0,
    streamLostAt: null,
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

// An open /workerEvents stream is a heartbeat between polls; it closes when the
// worker process does. Returns a detach function.
function attachWorkerStream(serverId, now = Date.now()) {
  const server = RobloxServers[serverId];
  if (!server) return () => {};
  server.streams += 1;
  server.streamLostAt = null;
  touchRobloxServer(serverId, now);
  return () => {
    server.streams -= 1;
    if (server.streams === 0) server.streamLostAt = Date.now();
  };
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
    notifyWorkers("task");
    logBot("Roblox Handoff", `task ${uuid} requeued for another worker`);
  }, DISPATCH_RETRY_MS);

  DispatchedTasks[uuid] = {
    task,
    timer,
    serverId,
    dispatchedAt: Date.now(),
  };
  return DispatchedTasks[uuid];
}

function taskMode(task) {
  return task?.nosandbox ? "nosandbox" : "sandbox";
}

// A server keeps its first task's mode. Studio workers never take --!nosandbox:
// unsandboxed code there would run on the bot's own host, so it goes to Open Cloud.
function canServeMode(server, mode) {
  if (mode === "nosandbox" && server.kind === "studio") return false;
  return !server.mode || server.mode === mode;
}

function canServe(server, task) {
  return canServeMode(server, taskMode(task));
}

function nextTaskFor(serverId) {
  const server = RobloxServers[serverId];
  if (!server || server.retiring) return null;
  for (const [uuid, task] of Object.entries(ExecuteTasks)) {
    if (canServe(server, task)) return uuid;
  }
  return null;
}

function reserveNextTask(serverId) {
  const server = RobloxServers[serverId];
  const uuid = nextTaskFor(serverId);
  if (!uuid) return null;
  const mode = taskMode(ExecuteTasks[uuid]);
  if (!dispatchTask(uuid, serverId)) return null;
  server.mode = mode;
  server.activeTaskIds.add(uuid);
  return uuid;
}

function getDispatchedTask(uuid) {
  return DispatchedTasks[uuid]?.task || null;
}

function serverForToken(token) {
  for (const tasks of [DispatchedTasks, ActiveRobloxTasks]) {
    for (const entry of Object.values(tasks)) {
      if (entry?.task?.token === token) return RobloxServers[entry.serverId] || null;
    }
  }
  return null;
}

function settleTasksForToken(token, finished = true) {
  for (const uuid of Object.keys(DispatchedTasks)) {
    const entry = DispatchedTasks[uuid];
    if (entry?.task?.token === token) {
      clearTimeout(entry.timer);
      delete DispatchedTasks[uuid];
      if (!finished) {
        // No retry timer now; only a server reap can recover it, so record where it went.
        ActiveRobloxTasks[uuid] = {
          ...entry,
          timer: null,
          startedAt: Date.now(),
        };
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

/**
 * Requeues tasks a lost server claimed but never started. One retry each, as
 * with the dispatch timer; already-retried ones are returned as `exhausted`.
 */
function requeueUnstartedTasksForServer(serverId) {
  const exhausted = [];
  let requeued = 0;
  for (const [uuid, entry] of Object.entries(DispatchedTasks)) {
    if (entry?.serverId !== serverId) continue;
    clearTimeout(entry.timer);
    delete DispatchedTasks[uuid];
    releaseServerTask(serverId, uuid);
    if (retriedTasks.has(entry.task)) {
      exhausted.push(entry.task);
      continue;
    }
    retriedTasks.add(entry.task);
    ExecuteTasks[uuid] = entry.task;
    requeued += 1;
  }
  if (requeued) notifyWorkers("task");
  return { requeued, exhausted };
}

function getUnfinishedTasksForServer(serverId) {
  return unfinishedTasksForServer(serverId, false);
}

function takeUnfinishedTasksForServer(serverId) {
  return unfinishedTasksForServer(serverId, true);
}

module.exports = {
  canServe,
  canServeMode,
  nextTaskFor,
  taskMode,
  state,
  SECRET_TOKEN,
  ExecuteTasks,
  CompilingTasks,
  Inputs,
  putInput,
  waitForInput,
  ScriptButtonCallbacks,
  docCodeStore,
  docPreviewStore,
  ActiveRobloxTasks,
  DispatchedTasks,
  RobloxServers,
  registerRobloxServer,
  touchRobloxServer,
  attachWorkerStream,
  retireRobloxServer,
  unregisterRobloxServer,
  dispatchTask,
  reserveNextTask,
  getDispatchedTask,
  serverForToken,
  settleTasksForToken,
  getUnfinishedTasksForServer,
  requeueUnstartedTasksForServer,
  takeUnfinishedTasksForServer,
};
