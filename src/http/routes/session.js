const { getActorBlock } = require("../../abuse");
const { client } = require("../../discord/client");
const {
  encodeZstd,
  getChunk,
  hasChunk,
  toWirePayload,
} = require("../../chunks");
const { MAX_ROBLOX_WORKERS, SERVER_RUN_TIME_MAX } = require("../../config");
const { closeSession, getSession } = require("../../core/sessions");
const {
  ExecuteTasks,
  Inputs,
  RobloxServers,
  getDispatchedTask,
  registerRobloxServer,
  reserveNextTask,
  state,
  touchRobloxServer,
} = require("../../state");
const { requireSecret } = require("../middleware");

const SERVER_NUMBER_MODULO = 256;

async function reserveNextAllowedTask(serverId) {
  while (true) {
    const taskId = Object.keys(ExecuteTasks)[0];
    if (!taskId) return null;

    const task = ExecuteTasks[taskId];
    const block = getActorBlock(task?.actorKey);
    if (!block) return reserveNextTask(serverId);

    delete ExecuteTasks[taskId];
    const session = getSession(task.token);
    if (session) {
      try {
        await session.responder.fail(
          new Error(
            `Failed to start. Try again in ${Math.ceil(block.remainingMs / 1000)} seconds.`,
          ),
          session.responder.link?.(),
        );
      } catch {}
    }
    closeSession(task.token);
  }
}

function heartbeatServer(serverId, now = Date.now()) {
  const server = RobloxServers[serverId];
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
    if (!existing && Object.keys(RobloxServers).length >= MAX_ROBLOX_WORKERS) {
      return res.status(429).json({ message: "Worker pool is full" });
    }

    registerRobloxServer(serverId);
    if (!existing && state.PendingRobloxStarts.length) {
      state.PendingRobloxStarts.shift();
    }
    state.SERVER_NUMBERS += 1;
    res.json({
      message: "Server started",
      id: state.SERVER_NUMBERS % SERVER_NUMBER_MODULO,
    });
  });

  app.post("/ping", requireSecret, (req, res) => {
    heartbeatServer(req.body.ServerId);
    res.json({ message: "Ping received" });
  });

  app.post("/getInputs", requireSecret, async (req, res) => {
    const interacted = req.body.i;
    if (!Array.isArray(interacted)) {
      return res.status(400).json({ message: "i must be an array of uids" });
    }

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
    res.json(toWirePayload(getDispatchedTask(taskId)));
  });

  app.post("/get", requireSecret, async (req, res) => {
    const TaskId = req.body.TaskId;
    const task = getDispatchedTask(TaskId);
    if (task) {
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
