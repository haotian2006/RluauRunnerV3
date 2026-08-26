const { ENABLE_LOCAL_EXEC } = require("../config");
const {
  acquireLocalExecution,
  codeHash,
  finishLocalExecutionHealth,
  getActorBlock,
  getLocalAdmissionBlock,
  heartbeatLocalExecution,
  isPunishableLuneExit,
  recordCrash,
  releaseLocalExecution,
  startLocalExecutionHealth,
} = require("../abuse");
const { closeSession, getSession } = require("../core/sessions");
const { logBot } = require("../log");
const { desugarConstForLune } = require("./constDesugar");
const { runLocal } = require("./run");
const { classify, describeClassification } = require("./router");

// Matches the bound the Roblox executor already applies before Discord.
const MAX_RESPONSE_LENGTH = 1900;
const LIVE_UPDATE_INTERVAL_MS = 1000;
const ANSI_RED = "\u001b[0;31m";
const ANSI_YELLOW = "\u001b[0;33m";
const ANSI_RESET = "\u001b[0m";
const localRunControllers = new Map();

function cancelLocalRun(token) {
  const controller = localRunControllers.get(token);
  if (!controller) return false;
  controller.abort();
  return true;
}

function formatEvent(event) {
  const value = String(event?.v ?? "");
  switch (event?.t) {
    case "out":
      return value;
    case "warn":
    case "truncated":
      return `${ANSI_YELLOW}${value}${ANSI_RESET}`;
    case "error":
    case "fatal":
      return `${ANSI_RED}${value}${ANSI_RESET}`;
    default:
      return value;
  }
}

function finishOutput(
  lines,
  result,
  maxLines = null,
  maxLength = MAX_RESPONSE_LENGTH,
) {
  if (result.error && !result.scriptErrored) {
    const color = result.timeoutKind === "yielding" ? ANSI_YELLOW : ANSI_RED;
    lines.push(`${color}${result.error}${ANSI_RESET}`);
  }

  let output = lines.filter(Boolean).join("\n");
  if (Number.isInteger(maxLines) && maxLines > 0) {
    const outputLines = output.split("\n");
    if (outputLines.length > maxLines) {
      output = outputLines.slice(-maxLines).join("\n");
    }
  }

  if (output.length <= maxLength) return output;

  const marker = "... [truncated]";

  const sliced = output
    .slice(0, maxLength - marker.length)
    .replace(/(?:\[[0-9;]*)?$/, "");
  return sliced + marker;
}

function localAdmissionError(actorKey) {
  const crashBlock = getActorBlock(actorKey);
  if (crashBlock) {
    return `Lune executions are temporarily blocked. Try again in ${Math.ceil(crashBlock.remainingMs / 1000)} seconds.`;
  }

  const stalledBlock = getLocalAdmissionBlock(actorKey);
  if (stalledBlock) {
    return `Failed to start. Try again in ${Math.ceil(stalledBlock.remainingMs / 1000)} seconds.`;
  }

  return null;
}

async function selectRuntime(source) {
  if (!ENABLE_LOCAL_EXEC) {
    return { runtime: "roblox", classification: null };
  }

  const classification = await classify(source);
  logBot("Local Router", describeClassification(classification));
  return {
    runtime: classification.eligible ? "lune" : "roblox",
    classification,
  };
}

/** Returns false when the caller should enqueue for Roblox instead. */
async function tryRunLocally(
  source,
  token,
  { actorKey = null, allowCodegen = false, selection = null } = {},
) {
  const selected = selection || (await selectRuntime(source));
  if (selected.runtime !== "lune") return false;

  source = await desugarConstForLune(source);

  let session = getSession(token);
  if (!session) return true;

  await session.responder.waitUntilReady?.();
  session = getSession(token);
  if (!session) return true;

  if (session.responder.hasStream?.() === false) {
    closeSession(token);
    return true;
  }
  const outputLineLimit = session.responder.outputLineLimit ?? null;
  const outputCharLimit = session.responder.outputCharLimit ?? MAX_RESPONSE_LENGTH;

  const admissionError = localAdmissionError(actorKey);
  if (admissionError) {
    await session.responder.fail(
      new Error(admissionError),
      session.responder.link?.(),
    );
    closeSession(token);
    return true;
  }

  if (!acquireLocalExecution(actorKey)) {
    await session.responder.fail(
      new Error("Too many concurrent Lune executions; try again shortly."),
      session.responder.link?.(),
    );
    closeSession(token);
    return true;
  }

  const lines = [];
  const startedAt = Date.now();
  const executionId = `lune:${token}:${startedAt}`;
  const controller = new AbortController();
  localRunControllers.set(token, controller);
  let liveUpdateTimer = null;
  let liveDelivery = Promise.resolve();
  let lastLiveOutput = "";

  function queueLiveUpdate() {
    const output = finishOutput(lines, {}, outputLineLimit, outputCharLimit);
    if (!output || output === lastLiveOutput) return;
    lastLiveOutput = output;

    liveDelivery = liveDelivery
      .then(async () => {
        const activeSession = getSession(token);
        if (!activeSession) return;
        await activeSession.responder.deliver({
          responseContent: output,
          fileMap: null,
          isLast: false,
          runtime: (Date.now() - startedAt) / 1000,
          serverNum: "Lune",
          followUp: false,
        });
      })
      .catch((error) => {
        logBot("Lune Live Update", error.message);
      });
  }

  try {
    liveUpdateTimer = setInterval(queueLiveUpdate, LIVE_UPDATE_INTERVAL_MS);
    const result = await runLocal(source, {
      allowCodegen,
      signal: controller.signal,
      beforeStart() {
        return localAdmissionError(actorKey);
      },
      onStarted() {
        startLocalExecutionHealth(actorKey, executionId);
      },
      onHeartbeat() {
        heartbeatLocalExecution(actorKey, executionId);
      },
      onEvent(event) {
        lines.push(formatEvent(event));
      },
    });
    clearInterval(liveUpdateTimer);
    liveUpdateTimer = null;
    await liveDelivery;

    if (result.admissionRejected) {
      session = getSession(token);
      if (session) {
        await session.responder.fail(
          new Error(result.error),
          session.responder.link?.(),
        );
      }
      return true;
    }

    if (isPunishableLuneExit(result)) {
      const crash = recordCrash(actorKey, executionId, [codeHash(source)]);
      if (crash?.newlyBlocked) {
        logBot("Lune Crash Attribution", `${actorKey}: blocked for 45s`);
      }
    }

    session = getSession(token);
    if (!session) return true;

    await session.responder.deliver({
      responseContent: finishOutput(lines, result, outputLineLimit, outputCharLimit),
      fileMap: null,
      isLast: true,
      runtime: (Date.now() - startedAt) / 1000,
      serverNum: "Lune",
      followUp: false,
    });
  } catch (error) {
    if (liveUpdateTimer) clearInterval(liveUpdateTimer);
    await liveDelivery;
    session = getSession(token);
    if (session) {
      await session.responder.fail(error, session.responder.link?.());
    }
  } finally {
    if (liveUpdateTimer) clearInterval(liveUpdateTimer);
    if (localRunControllers.get(token) === controller) {
      localRunControllers.delete(token);
    }
    finishLocalExecutionHealth(actorKey, executionId);
    releaseLocalExecution(actorKey);
    closeSession(token);
  }

  return true;
}

module.exports = { cancelLocalRun, selectRuntime, tryRunLocally };
