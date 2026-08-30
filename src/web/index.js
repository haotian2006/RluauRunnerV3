const { codeHash, getActorBlock } = require("../abuse");
const { MAX_DATA_TO_SEND, TRUST_PROXY } = require("../config");
const { encodeZstd } = require("../chunks");
const { closeSession, getSession, openSession } = require("../core/sessions");
const {
  cancelLocalRun,
  deliverLocalInputToToken,
  selectRuntime,
  tryRunLocally,
} = require("../local/dispatch");
const { safeMessage } = require("../sanitize");
const { log } = require("../log");
const { ExecuteTasks, Inputs } = require("../state");
const { formatLuau } = require("../tools/luau");
const { generateUUID } = require("../util");
const {
  RUN_RATE_LIMIT,
  checkFormatDebounce,
  checkRunRate,
  describeSubmission,
  hashIp,
} = require("./rateLimit");
const { createSseResponder } = require("./sse");

const SESSION_TIMEOUT_MS = 1000 * 60 * 6;
const INPUT_TTL_MS = 1000 * 30;
const UPLOAD_CHUNK_TTL_MS = 1000 * 60 * 2;
const MAX_UPLOAD_CHUNK_BASE64 = 1024 * 1024;
const MAX_PARALLEL_UPLOADS_PER_SESSION = 5;
const MAX_UPLOAD_CHUNKS = 1000;

const PendingInputUploads = {};

const WebTasks = new Map();

function clearPendingUpload(token, uploadId) {
  const tokenUploads = PendingInputUploads[token];
  if (!tokenUploads || !tokenUploads[uploadId]) return;
  clearTimeout(tokenUploads[uploadId].timeoutId);
  delete tokenUploads[uploadId];
  if (Object.keys(tokenUploads).length === 0) delete PendingInputUploads[token];
}

function clearAllPendingUploads(token) {
  const tokenUploads = PendingInputUploads[token];
  if (!tokenUploads) return;
  for (const uploadId in tokenUploads) {
    clearTimeout(tokenUploads[uploadId].timeoutId);
  }
  delete PendingInputUploads[token];
}

function queueInput(token, value) {
  deliverLocalInputToToken(token, value);
  const uid = generateUUID();
  Inputs[uid] = { uid, id: token, input: value };
  setTimeout(() => delete Inputs[uid], INPUT_TTL_MS);
}

function releaseWebRun(token, timeoutId) {
  clearTimeout(timeoutId);
  // Runs on every session teardown - explicit /stop and a bare browser
  // disconnect alike - so a closed tab doesn't leave a Lune process or an
  // already-dispatched Roblox task running for a client that's gone.
  cancelLocalRun(token);
  queueInput(token, "STOP_ALL_SESSIONS_PLS");
  const taskId = WebTasks.get(token);
  if (taskId) {
    delete ExecuteTasks[taskId];
    WebTasks.delete(token);
  }
  clearAllPendingUploads(token);
}

function endWebSession(token, reason) {
  const session = getSession(token);
  if (session) {
    session.responder.close(reason);
    closeSession(token);
  } else {
    releaseWebRun(token);
  }
}

const tooLarge = () => ({
  error: `File too large (max ${MAX_DATA_TO_SEND / 1024 / 1024}MB)`,
});

function registerWebRoutes(app) {
  app.set("trust proxy", TRUST_PROXY);

  app.post("/run", async (req, res) => {
    const { code } = req.body;
    if (!code || typeof code !== "string") {
      return res.status(400).json({ error: "Missing code" });
    }

    const anonIp = hashIp(req.ip);
    if (!checkRunRate(req.ip)) {
      return res
        .status(429)
        .json({ error: `Rate limit: max ${RUN_RATE_LIMIT} runs/min` });
    }

    const selection = await selectRuntime(code);
    let actorKey = `web:${anonIp}:${selection.runtime}`;
    const block = getActorBlock(actorKey);
    if (block) {
      return res.status(429).json({
        error: `Failed to start. Try again in ${Math.ceil(block.remainingMs / 1000)} seconds.`,
      });
    }

    let encoded;
    try {
      encoded = encodeZstd(code);
    } catch (err) {
      return res.status(500).json({ error: safeMessage(err) });
    }
    if (encoded.length > MAX_DATA_TO_SEND) {
      return res
        .status(400)
        .json({ error: "Code too large after compression" });
    }

    const token = generateUUID() + generateUUID();
    const taskId = generateUUID();

    log(anonIp, "web", "compile", describeSubmission(code));

    const task = {
      content: encoded,
      channelId: "web",
      targetId: null,
      id: token,
      token: token,
      userId: token,
      username: anonIp,
      actorKey,
      codeHash: codeHash(code),
      isCommand: false,
      isWeb: true,
    };

    let timeoutId;
    const responder = createSseResponder(() => releaseWebRun(token, timeoutId));
    openSession(token, responder);
    timeoutId = setTimeout(() => {
      endWebSession(token, "Session timed out");
    }, SESSION_TIMEOUT_MS);

    res.json({ token });

    void (async () => {
      const session = getSession(token);
      if (!session) return;
      await session.responder.waitUntilReady?.();
      if (session.responder.hasStream?.() === false) {
        closeSession(token);
        return;
      }
      if (!getSession(token)) return;

      const ranLocally = await tryRunLocally(code, token, {
        actorKey,
        selection,
        allowCodegen: true,
      });
      if (ranLocally || !getSession(token)) return;
      if (selection.runtime === "lune") {
        actorKey = `web:${anonIp}:roblox`;
        task.actorKey = actorKey;
        const fallbackBlock = getActorBlock(actorKey);
        if (fallbackBlock) {
          await getSession(token)?.responder.fail(
            new Error(
              `Failed to start. Try again in ${Math.ceil(fallbackBlock.remainingMs / 1000)} seconds.`,
            ),
          );
          closeSession(token);
          return;
        }
      }
      ExecuteTasks[taskId] = task;
      WebTasks.set(token, taskId);
    })();
  });

  app.post("/format", async (req, res) => {
    const { code } = req.body;
    if (typeof code !== "string") {
      return res.status(400).json({ error: "Missing code" });
    }

    if (!checkFormatDebounce(req.ip)) {
      return res
        .status(429)
        .json({ error: "Rate limit: max 1 format request per 0.5 seconds" });
    }

    if (code.length > MAX_DATA_TO_SEND) {
      return res.status(400).json({ error: "Code too large" });
    }

    log(hashIp(req.ip), "web", "format", describeSubmission(code));

    try {
      const result = await formatLuau(code);
      if (result.code !== 0) {
        return res.status(400).json({ error: result.output });
      }
      res.json({ formatted: result.output });
    } catch (err) {
      res.status(500).json({ error: safeMessage(err) });
    }
  });

  app.get("/stream/:token", (req, res) => {
    const session = getSession(req.params.token);
    if (!session) {
      return res.status(404).json({ error: "Session not found or expired" });
    }

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");
    res.setHeader("X-Accel-Buffering", "no"); // nginx would buffer otherwise
    res.flushHeaders();

    session.responder.attach(res);
  });

  app.post("/stop/:token", (req, res) => {
    const token = req.params.token;

    log(hashIp(req.ip), "web", "stop", "User stopped execution");

    cancelLocalRun(token);
    queueInput(token, "STOP_ALL_SESSIONS_PLS");
    endWebSession(token, "Stopped by user");

    res.json({ message: "Stopped" });
  });

  app.post("/input/:token", (req, res) => {
    const { input, isFile, isFileChunk, uploadId, index, total } = req.body;
    const token = req.params.token;
    if (!getSession(token)) {
      return res.status(404).json({ error: "Session not found" });
    }

    if (isFileChunk) {
      if (!isFile || typeof input !== "string") {
        return res.status(400).json({ error: "Missing file chunk data" });
      }
      if (
        typeof uploadId !== "string" ||
        !Number.isInteger(index) ||
        !Number.isInteger(total)
      ) {
        return res.status(400).json({ error: "Invalid chunk metadata" });
      }
      if (total <= 0 || total > MAX_UPLOAD_CHUNKS) {
        return res.status(400).json({ error: "Invalid chunk count" });
      }
      if (index < 0 || index >= total) {
        return res.status(400).json({ error: "Invalid chunk index" });
      }
      if (input.length > MAX_UPLOAD_CHUNK_BASE64) {
        return res.status(400).json({ error: "Chunk too large" });
      }

      if (!PendingInputUploads[token]) PendingInputUploads[token] = {};
      const tokenUploads = PendingInputUploads[token];

      if (!tokenUploads[uploadId]) {
        if (
          Object.keys(tokenUploads).length >= MAX_PARALLEL_UPLOADS_PER_SESSION
        ) {
          return res.status(429).json({ error: "Too many active uploads" });
        }
        tokenUploads[uploadId] = {
          total,
          chunks: new Array(total),
          received: 0,
          totalBytes: 0,
          timeoutId: setTimeout(
            () => clearPendingUpload(token, uploadId),
            UPLOAD_CHUNK_TTL_MS,
          ),
        };
      }

      const upload = tokenUploads[uploadId];
      if (upload.total !== total) {
        return res.status(400).json({ error: "Mismatched chunk total" });
      }

      if (!upload.chunks[index]) {
        const chunkBuf = Buffer.from(input, "base64");
        if (chunkBuf.length === 0 && input.length > 0) {
          return res.status(400).json({ error: "Invalid base64 chunk" });
        }
        upload.chunks[index] = chunkBuf;
        upload.received += 1;
        upload.totalBytes += chunkBuf.length;
        if (upload.totalBytes > MAX_DATA_TO_SEND) {
          clearPendingUpload(token, uploadId);
          return res.status(400).json(tooLarge());
        }
      }

      if (upload.received < upload.total) {
        return res.json({
          message: "Chunk received",
          complete: false,
          received: upload.received,
          total: upload.total,
        });
      }

      const joined = Buffer.concat(upload.chunks);
      clearPendingUpload(token, uploadId);
      if (joined.length > MAX_DATA_TO_SEND) {
        return res.status(400).json(tooLarge());
      }

      log(
        hashIp(req.ip),
        "web",
        "input",
        `File uploaded: ${joined.length} bytes`,
      );
      queueInput(token, joined);
      return res.json({ message: "Sent", complete: true });
    }

    if (typeof input !== "string") {
      return res.status(400).json({ error: "Missing input" });
    }

    const anonIp = hashIp(req.ip);
    let value;
    if (isFile) {
      const buf = Buffer.from(input, "base64");
      if (buf.length > MAX_DATA_TO_SEND) {
        return res.status(400).json(tooLarge());
      }
      value = buf;
      log(anonIp, "web", "input", `File sent: ${buf.length} bytes`);
    } else {
      value = input;
      log(anonIp, "web", "input", "Text input sent");
    }

    queueInput(token, value);
    res.json({ message: "Sent" });
  });
}

module.exports = { registerWebRoutes };
