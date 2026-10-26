const { getActorBlock } = require("../../abuse");
const { client } = require("../../discord/client");
const {
  encodeZstd,
  getChunk,
  hasChunk,
  toWirePayload,
} = require("../../chunks");
const {
  SERVER_RUN_TIME_MAX,
  STUDIO_ACCEPT_MS,
  STUDIO_DRAIN_MS,
  STUDIO_SESSION_MS,
} = require("../../config");
const { closeSession, getSession } = require("../../core/sessions");
const { grantStorage } = require("../../dataStores");
const { logBot } = require("../../log");
const { getMaxWorkers } = require("../../profiles");
const {
  ExecuteTasks,
  Inputs,
  RobloxServers,
  getDispatchedTask,
  nextTaskFor,
  registerRobloxServer,
  reserveNextTask,
  retireRobloxServer,
  state,
  touchRobloxServer,
  attachWorkerStream,
  waitForInput,
} = require("../../state");
const { openWorkerStream } = require("../../workerEvents");
const { requireSecret } = require("../middleware");

const SERVER_NUMBER_MODULO = 256;
// Cloudflare drops a request after 100s; stay well under it.
const MAX_INPUT_WAIT_SECONDS = 25;

async function reserveNextAllowedTask(serverId) {
  while (true) {
    const taskId = nextTaskFor(serverId);
    if (!taskId) return null;

    const task = ExecuteTasks[taskId];
    const block = getActorBlock(task?.actorKey);
    if (!block) return reserveNextTask(serverId);

    delete ExecuteTasks[taskId];
    logBot(
      "Roblox Handoff",
      `task ${taskId} dropped from the queue: ${task.actorKey} is blocked ` +
        `for another ${Math.ceil(block.remainingMs / 1000)}s`,
    );
    const session = getSession(task.token);
    if (session) {
      Promise.resolve(
        session.responder.fail(
          new Error(
            `Failed to start. Try again in ${Math.ceil(block.remainingMs / 1000)} seconds.`,
          ),
          session.responder.link?.(),
        ),
      ).catch(() => {});
    }
    closeSession(task.token);
  }
}

// A Studio session hands over once a younger one is taking tasks (so one of two
// warm workers always accepts); alone, it accepts until the drain window.
function studioSessionDone(server, now) {
  const age = now - server.startedAt;
  if (age >= STUDIO_SESSION_MS - STUDIO_DRAIN_MS) return true;
  if (age < STUDIO_ACCEPT_MS) return false;
  return Object.values(RobloxServers).some(
    (other) =>
      other.kind === "studio" &&
      other.healthy &&
      !other.retiring &&
      other.startedAt > server.startedAt,
  );
}

function heartbeatServer(serverId, now = Date.now()) {
  const server = RobloxServers[serverId];
  if (server?.kind === "studio" && studioSessionDone(server, now)) {
    server.retiring = true;
  }
  if (
    server &&
    !server.healthy &&
    now - server.startedAt >= SERVER_RUN_TIME_MAX
  ) {
    server.retiring = true;
    return server;
  }
  return touchRobloxServer(serverId, now);
}

function registerSessionRoutes(app) {
  app.get("/", (req, res) => {
    res.send("Bot is running!");
  });

  app.get("/stats", (req, res) => {
    if (!client.isReady()) {
      return res.status(503).json({ error: "Bot not ready" });
    }
    const guilds = client.guilds.cache;
    res.json({
      guilds: guilds.size,
      memberReach: guilds.reduce((sum, g) => sum + g.memberCount, 0),
    });
  });

  app.post("/start", requireSecret, async (req, res) => {
    const serverId = req.body.ServerId;
    if (typeof serverId !== "string" || !serverId) {
      return res.status(400).json({ message: "ServerId is required" });
    }
    const existing = RobloxServers[serverId];
    const studio = req.studioWorker === true;
    const cloudServers = Object.values(RobloxServers).filter((s) => s.kind !== "studio").length;
    if (!existing && !studio && cloudServers >= getMaxWorkers()) {
      logBot(
        "Roblox Server",
        `${serverId} refused: pool already holds ${cloudServers}/${getMaxWorkers()}`,
      );
      return res.status(429).json({ message: "Worker pool is full" });
    }

    const server = registerRobloxServer(serverId);
    if (studio) server.kind = "studio";
    if (!existing && !studio && state.PendingRobloxStarts.length) {
      state.PendingRobloxStarts.shift();
    }
    state.SERVER_NUMBERS += 1;
    res.json({
      message: "Server started",
      id: state.SERVER_NUMBERS % SERVER_NUMBER_MODULO,
    });
  });

  // Workers pass their ServerId so the open stream counts as their heartbeat.
  app.get("/workerEvents", requireSecret, (req, res) => {
    const detach = attachWorkerStream(req.query?.ServerId);
    openWorkerStream(req, res);
    res.on("close", detach);
  });

  app.post("/ping", requireSecret, (req, res) => {
    heartbeatServer(req.body.ServerId);
    res.json({ message: "Ping received" });
  });

  app.post("/retire", requireSecret, (req, res) => {
    retireRobloxServer(req.body.ServerId);
    res.json({ message: "Server retiring" });
  });

  app.post("/getInputs", requireSecret, async (req, res) => {
    const interacted = req.body.i;
    if (!Array.isArray(interacted)) {
      return res.status(400).json({ message: "i must be an array of uids" });
    }

    const collect = () => {
      const data = [];
      for (const id in Inputs) {
        if (!interacted.includes(Inputs[id].uid)) {
          if (!Inputs[id].encoded) {
            Inputs[id].content = encodeZstd(Inputs[id].input);
            Inputs[id].encoded = true;
            delete Inputs[id].input;
          }

          data.push(toWirePayload(Inputs[id]));
        }
      }
      return data;
    };

    let data = collect();
    // Long poll: with nothing queued, wait for an input so clicks reach Roblox
    // in one round trip.
    const wait = Number(req.body.wait);
    if (data.length === 0 && wait > 0) {
      const aborted = new AbortController();
      res.on("close", () => aborted.abort());
      await waitForInput(Math.min(wait, MAX_INPUT_WAIT_SECONDS) * 1000, aborted.signal);
      if (aborted.signal.aborted) return;
      data = collect();
    }
    res.json(data);
  });

  app.post("/getAll", requireSecret, async (req, res) => {
    const serverId = req.body.ServerId;
    const server = heartbeatServer(serverId);

    if (!server || server.retiring) {
      return res.status(201).json({ message: "New Session" });
    }

    const taskId = await reserveNextAllowedTask(serverId);
    res.json(taskId ? [taskId] : []);
  });

  // New workers reserve and receive one task atomically
  app.post("/getNext", requireSecret, async (req, res) => {
    const serverId = req.body.ServerId;
    const server = heartbeatServer(serverId);

    if (!server || server.retiring) {
      return res.status(201).json({ message: "New Session" });
    }

    const taskId = await reserveNextAllowedTask(serverId);
    if (!taskId) return res.status(204).end();
    const task = getDispatchedTask(taskId);
    grantStorage(task);
    res.json(toWirePayload(task));
  });

  app.post("/get", requireSecret, async (req, res) => {
    const TaskId = req.body.TaskId;
    const task = getDispatchedTask(TaskId);
    if (task) {
      grantStorage(task);
      const payload = toWirePayload(task);
      res.json(payload);
      return;
    }
    res.status(404).json({ message: "Task not found" });
  });

  app.post("/chunk", requireSecret, async (req, res) => {
    const chunkId = req.body.id;
    if (hasChunk(chunkId)) {
      res.status(200).json({ chunk: getChunk(chunkId) });
    } else {
      res.status(404).json({ message: "Chunk not found" });
    }
  });
}

module.exports = { registerSessionRoutes };
