const {
  encodeZstd,
  getChunk,
  hasChunk,
  toWirePayload,
} = require("../../chunks");
const { ExecuteTasks, Inputs, dispatchTask, state } = require("../../state");
const { requireSecret } = require("../middleware");

const SERVER_NUMBER_MODULO = 256;

function registerSessionRoutes(app) {
  app.get("/", (req, res) => {
    res.send("Bot is running!");
  });

  app.post("/start", requireSecret, async (req, res) => {
    state.RunningServer = req.body.ServerId;
    state.RunningServerTime = Date.now();
    state.SERVER_NUMBERS += 1;
    res.json({
      message: "Server started",
      id: state.SERVER_NUMBERS % SERVER_NUMBER_MODULO,
    });
  });

  app.post("/ping", requireSecret, (req, res) => {
    if (req.body.ServerId === state.RunningServer) {
      state.LastServerPing = Date.now();
    }
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
    const ServerId = req.body.ServerId;

    if (ServerId === state.RunningServer) {
      state.LastServerPing = Date.now();
      const Ids = [];
      for (const id in ExecuteTasks) {
        Ids.push(id);
      }
      res.json(Ids);
    } else {
      res.status(201).json({ message: "New Session" });
    }
  });

  app.post("/get", requireSecret, async (req, res) => {
    const TaskId = req.body.TaskId;
    if (TaskId in ExecuteTasks) {
      const payload = toWirePayload(ExecuteTasks[TaskId]);

      dispatchTask(TaskId);
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

  app.post("/test", async (req, res) => {
    console.log("Test endpoint hit", req.body[0]);
    res.json({ message: "Test endpoint response" });
  });
}

module.exports = { registerSessionRoutes };
