const {
  INPUT_WINDOW_MS,
  checkInputRate,
  codeHash,
  getActorBlock,
} = require("../abuse");
const { MAX_DATA_TO_SEND, TRUST_PROXY } = require("../config");
const { encodeZstd } = require("../chunks");
const { closeSession, getSession, openSession } = require("../core/sessions");
const {
  cancelLocalRun,
  deliverLocalInputToToken,
  selectRuntime,
  tryRunLocally,
} = require("../local/dispatch");
const { ROBLOX_KEY, limiterKey } = require("../origin");
const { safeMessage } = require("../sanitize");
const { log } = require("../log");
const { record } = require("../metrics");
const { ExecuteTasks, Inputs } = require("../state");
const { getByteCodeOptions } = require("../tools/bytecode");
const { compileLuau, formatLuau, generateAST } = require("../tools/luau");
const { generateUUID } = require("../util");
const {
  POLL_RATE_LIMIT,
  RUN_RATE_LIMIT,
  TOOL_DEBOUNCE_MS,
  TOOL_RATE_LIMIT,
  checkFormatDebounce,
  checkPollRate,
  checkRunRate,
  checkToolDebounce,
  checkToolRate,
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
const POLL_GRACE_MS = 1000 * 30;
const POLL_SWEEP_MS = 1000 * 10;
const RESULT_TTL_MS = 1000 * 60 * 2;
const MAX_STORED_RESULTS = 500;

const PendingInputUploads = {};

const WebTasks = new Map();

// A polling client has no socket to hang up, so its last GET /result stands in
// for one: stop asking and the run is torn down the way a closed tab tears down
// an SSE run.
const PollSessions = new Map();

// The session is gone the moment a run finishes, so its last snapshot outlives
// it here - long enough for the client's next poll to collect the result.
const WebResults = new Map();

function rememberResult(token, snapshot) {
  const existing = WebResults.get(token);
  if (existing) clearTimeout(existing.timeoutId);
  else if (WebResults.size >= MAX_STORED_RESULTS) {
    const oldest = WebResults.keys().next().value;
    clearTimeout(WebResults.get(oldest).timeoutId);
    WebResults.delete(oldest);
  }
  const timeoutId = setTimeout(() => WebResults.delete(token), RESULT_TTL_MS);
  timeoutId.unref?.();
  WebResults.set(token, { snapshot, timeoutId });
}

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
  PollSessions.delete(token);
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

// A compile or parse never needs the 100MB upload allowance; anything past this
// is not a real script, and rejecting it early keeps a large-input flood from
// tying up compiler processes.
const MAX_TOOL_CODE_BYTES = 1024 * 1024;

class InvalidBytecodeOptions extends Error {}

function bytecodeOptionsForRequest(code, overrides) {
  const options = getByteCodeOptions(code);
  if (overrides === undefined) return options;
  if (!overrides || typeof overrides !== "object" || Array.isArray(overrides) ||
      Object.keys(overrides).some((key) => !["optimizeLevel", "debugLevel", "typeLevel", "output"].includes(key))) {
    throw new InvalidBytecodeOptions("Invalid bytecode options");
  }
  for (const level of ["optimizeLevel", "debugLevel", "typeLevel"]) {
    if (overrides[level] === undefined) continue;
    const max = level === "typeLevel" ? 1 : 2;
    if (!Number.isInteger(overrides[level]) || overrides[level] < 0 || overrides[level] > max) {
      throw new InvalidBytecodeOptions(`${level} must be between 0 and ${max}`);
    }
    options[level] = overrides[level];
  }
  if (overrides.output !== undefined) {
    const output = overrides.output;
    if (!["vm", "constants", "remarks", "binary", "native-x64", "native-a64", "asm-x64", "asm-a64"].includes(output)) {
      throw new InvalidBytecodeOptions("Invalid bytecode output format");
    }
    options.native = output.startsWith("native-");
    options.asm = output.startsWith("asm-");
    options.binary = output === "binary";
    options.remarks = output === "remarks";
    options.constants = output === "constants";
    if (options.native || options.asm) {
      options.architecture = output.endsWith("-a64") ? "a64" : "x64";
    }
  }
  return options;
}

// Each entry owns the whole tool: how to run it, and what the JSON body calls
// its output. The plain-text GET variant returns `output` on its own.
const TOOLS = {
  bytecode: {
    field: "bytecode",
    async run(code, overrides) {
      const options = bytecodeOptionsForRequest(code, overrides);
      const result = await compileLuau(code, options);
      return { ...result, extra: { options } };
    },
  },
  ast: {
    field: "ast",
    run: (code) => generateAST(code),
  },
};

// All of Roblox shares one identity: one script looping over /run from a game
// server would otherwise arrive as an endless supply of fresh datacenter IPs.
function callerFor(req) {
  const key = limiterKey(req);
  return { key, label: key === ROBLOX_KEY ? ROBLOX_KEY : hashIp(req.ip) };
}

function readToolCode(req) {
  const value = req.method === "GET" ? req.query.code : req.body?.code;
  return typeof value === "string" ? value : null;
}

// A tool run costs a compiler process, so it is limited the way /format is -
// no back-to-back calls - plus a per-minute ceiling.
async function handleTool(req, res, name, { raw }) {
  const tool = TOOLS[name];
  const code = readToolCode(req);

  const fail = (status, message) =>
    raw
      ? res.status(status).type("text/plain; charset=utf-8").send(message)
      : res.status(status).json({ error: message });

  record("web", name);
  if (code === null) return fail(400, "Missing code");
  if (Buffer.byteLength(code, "utf8") > MAX_TOOL_CODE_BYTES) {
    return fail(
      400,
      `Code too large (max ${MAX_TOOL_CODE_BYTES / 1024} KB)`,
    );
  }

  const caller = callerFor(req);
  if (!checkToolDebounce(caller.key, name)) {
    record("limited", name);
    return fail(
      429,
      `Rate limit: max 1 ${name} request per ${TOOL_DEBOUNCE_MS / 1000} seconds`,
    );
  }
  if (!checkToolRate(caller.key, name)) {
    record("limited", name);
    return fail(429, `Rate limit: max ${TOOL_RATE_LIMIT} ${name} requests/min`);
  }

  log(caller.label, "web", name, describeSubmission(code));

  let result;
  try {
    result = await tool.run(code, name === "bytecode" && !raw ? req.body?.options : undefined);
  } catch (err) {
    if (err instanceof InvalidBytecodeOptions) return fail(400, err.message);
    return fail(500, safeMessage(err));
  }

  // -1 is the tool timeout; anything else non-zero is the tool rejecting the
  // source, and its own message is the useful part of the answer.
  if (result.code !== 0) {
    return fail(result.code === -1 ? 504 : 400, result.output);
  }

  if (raw) {
    res.setHeader("X-Content-Type-Options", "nosniff");
    return res.type("text/plain; charset=utf-8").send(result.output);
  }
  res.json({ [tool.field]: result.output, ...(result.extra || {}) });
}

function sweepPollSessions(now = Date.now()) {
  for (const [token, lastPolledAt] of PollSessions) {
    if (now - lastPolledAt > POLL_GRACE_MS) {
      endWebSession(token, "Client stopped polling");
    }
  }
}

const pollSweep = setInterval(sweepPollSessions, POLL_SWEEP_MS);
pollSweep.unref();

const tooLarge = () => ({
  error: `File too large (max ${MAX_DATA_TO_SEND / 1024 / 1024}MB)`,
});

function registerWebRoutes(app) {
  app.set("trust proxy", TRUST_PROXY);

  app.post("/run", async (req, res) => {
    record("web", "run");
    const { code, stream } = req.body;
    if (!code || typeof code !== "string") {
      return res.status(400).json({ error: "Missing code" });
    }
    // Opt-in: the session runs with no SSE and the client reads GET /result.
    const poll = stream === false;

    const { key: callerKey, label: anonIp } = callerFor(req);
    if (!checkRunRate(callerKey)) {
      record("limited", "run");
      return res
        .status(429)
        .json({ error: `Rate limit: max ${RUN_RATE_LIMIT} runs/min` });
    }

    const selection = await selectRuntime(code);
    record("run", `web:${selection.runtime}`);
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
    const responder = createSseResponder(
      () => {
        rememberResult(token, responder.snapshot());
        releaseWebRun(token, timeoutId);
      },
      { requireStream: !poll },
    );
    openSession(token, responder);
    if (poll) PollSessions.set(token, Date.now());
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
    record("web", "format");
    const { code } = req.body;
    if (typeof code !== "string") {
      return res.status(400).json({ error: "Missing code" });
    }

    if (!checkFormatDebounce(callerFor(req).key)) {
      record("limited", "format");
      return res
        .status(429)
        .json({ error: "Rate limit: max 1 format request per 0.5 seconds" });
    }

    if (code.length > MAX_DATA_TO_SEND) {
      return res.status(400).json({ error: "Code too large" });
    }

    log(callerFor(req).label, "web", "format", describeSubmission(code));

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

  for (const name of Object.keys(TOOLS)) {
    app.post(`/${name}`, (req, res) => handleTool(req, res, name, { raw: false }));
    app.get(`/${name}`, (req, res) => handleTool(req, res, name, { raw: true }));
  }

  app.get("/stream/:token", (req, res) => {
    record("web", "stream");
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

  // Serves a live session from its responder and a finished one from the
  // retained snapshot, so a client that polls a moment late still gets output.
  app.get("/result/:token", (req, res) => {
    record("web", "result");
    if (!checkPollRate(callerFor(req).key)) {
      record("limited", "result");
      return res
        .status(429)
        .json({ error: `Rate limit: max ${POLL_RATE_LIMIT} polls/min` });
    }

    const token = req.params.token;
    const session = getSession(token);
    if (session) {
      if (PollSessions.has(token)) PollSessions.set(token, Date.now());
      return res.json({ token, ...session.responder.snapshot() });
    }

    const stored = WebResults.get(token);
    if (stored) return res.json({ token, ...stored.snapshot });

    res.status(404).json({ error: "Session not found or expired" });
  });

  app.post("/stop/:token", (req, res) => {
    record("web", "stop");
    const token = req.params.token;

    log(callerFor(req).label, "web", "stop", "User stopped execution");

    cancelLocalRun(token);
    queueInput(token, "STOP_ALL_SESSIONS_PLS");
    endWebSession(token, "Stopped by user");

    res.json({ message: "Stopped" });
  });

  app.post("/input/:token", (req, res) => {
    record("web", "input");
    const { input, isFile, isFileChunk, uploadId, index, total } = req.body;
    const token = req.params.token;
    if (!getSession(token)) {
      return res.status(404).json({ error: "Session not found" });
    }

    const anonIp = callerFor(req).label;
    const rate = checkInputRate(
      `web:${anonIp}`,
      isFileChunk ? "chunk" : "input",
    );
    if (!rate.allowed) {
      record("limited", "input");
      return res.status(429).json({
        error: `Rate limit: max ${rate.limit} inputs per ${Math.round(INPUT_WINDOW_MS / 1000)}s. Try again in ${Math.ceil(rate.remainingMs / 1000)} seconds.`,
      });
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

      log(anonIp, "web", "input", `File uploaded: ${joined.length} bytes`);
      queueInput(token, joined);
      return res.json({ message: "Sent", complete: true });
    }

    if (typeof input !== "string") {
      return res.status(400).json({ error: "Missing input" });
    }

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

module.exports = { POLL_GRACE_MS, registerWebRoutes, sweepPollSessions };
