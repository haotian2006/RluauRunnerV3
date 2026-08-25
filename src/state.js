const state = {
  CallbackUrl: "",

  RunningServer: "",
  RunningServerTime: 0,
  LastServerPing: 0,
  LastServerCreation: 0,

  SERVERS_CREATED: 0,
  SERVER_NUMBERS: 0,
};

const SECRET_TOKEN =
  Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);

const ExecuteTasks = {};

const CompilingTasks = {};

const Inputs = {};

const ScriptButtonCallbacks = new Map();

const docCodeStore = {};

const DispatchedTasks = {};

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

function dispatchTask(uuid) {
  const task = ExecuteTasks[uuid];
  if (!task) return;
  delete ExecuteTasks[uuid];

  const previous = DispatchedTasks[uuid];
  if (previous) clearTimeout(previous.timer);

  const timer = setTimeout(() => {
    delete DispatchedTasks[uuid];
    if (retriedTasks.has(task)) return;

    if (!CompilingTasks[task.token]) return;
    retriedTasks.add(task);
    ExecuteTasks[uuid] = task;
  }, DISPATCH_RETRY_MS);

  DispatchedTasks[uuid] = { task, timer };
}

function settleTasksForToken(token) {
  for (const uuid of Object.keys(DispatchedTasks)) {
    const entry = DispatchedTasks[uuid];
    if (entry?.task?.token === token) {
      clearTimeout(entry.timer);
      delete DispatchedTasks[uuid];
    }
  }
}

module.exports = {
  state,
  SECRET_TOKEN,
  ExecuteTasks,
  CompilingTasks,
  Inputs,
  ScriptButtonCallbacks,
  docCodeStore,
  dispatchTask,
  settleTasksForToken,
};
