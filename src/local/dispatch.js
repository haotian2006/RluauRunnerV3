const {
  ENABLE_LOCAL_EXEC,
  LOCAL_FORCED_TIMEOUT_MS,
  LOCAL_TIMEOUT_MS,
  MAX_RESPONSE_FILES,
  SupportedFileTypes,
} = require("../config");
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
// Beyond the run's own timeout, how long to wait for a terminal embed before
// declaring the run stalled. Generous on purpose: a slow Discord edit is not a
// stall, a run that never reports anything is.
const TERMINAL_UPDATE_GRACE_MS = 60000;
const ANSI_RED = "\u001b[0;31m";
const ANSI_YELLOW = "\u001b[0;33m";
const ANSI_RESET = "\u001b[0m";
const localRunControllers = new Map();

function cancelLocalRun(token) {
  const run = localRunControllers.get(token);
  if (!run) return false;
  run.controller.abort();
  return true;
}

function deliverLocalInput(userId, value) {
  const actorKey = `discord:${userId}:lune`;
  let delivered = 0;
  for (const run of localRunControllers.values()) {
    if (run.actorKey !== actorKey) continue;
    if (run.sendInput?.(value)) {
      delivered += 1;
    } else if (run.pendingInputs.length < 32) {
      run.pendingInputs.push(value);
      delivered += 1;
    }
  }
  return delivered;
}

function deliverLocalInputToToken(token, value) {
  const run = localRunControllers.get(token);
  if (!run) return false;
  if (run.sendInput?.(value)) return true;
  if (run.pendingInputs.length >= 32) return false;
  run.pendingInputs.push(value);
  return true;
}

const SAFE_FILE_NAME = /[^A-Za-z0-9_-]/g;

function parseLocalFileName(raw) {
  let fileType = raw;
  let fileName;
  if (typeof raw === "string" && raw.includes(".")) {
    [fileName, fileType] = raw.split(".");
  }
  fileType =
    typeof fileType === "string" && SupportedFileTypes.has(fileType.toLowerCase())
      ? fileType.toLowerCase()
      : "ansi";
  fileName =
    typeof fileName === "string"
      ? fileName.replace(SAFE_FILE_NAME, "").slice(0, 64)
      : "";
  return { fileName: fileName || "output", fileType };
}

function recordLocalFile(fileMap, rawName, data) {
  const { fileName, fileType } = parseLocalFileName(rawName);
  const key = `${fileName}.${fileType}`;
  if (!fileMap.has(key) && fileMap.size >= MAX_RESPONSE_FILES) {
    fileMap.delete(fileMap.keys().next().value);
  }
  fileMap.set(key, [data, fileType, fileName]);
  return key;
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

function localTimeoutForSelection(selection) {
  return selection?.classification?.forced
    ? LOCAL_FORCED_TIMEOUT_MS
    : LOCAL_TIMEOUT_MS;
}

function queueLuneWhenBusy(selection) {
  return selection?.classification?.forced === true;
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
    if (!queueLuneWhenBusy(selected)) {
      return false;
    }
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
  let terminalUpdateSent = false;
  // Last line of defence. Every stall found so far ended the same way: the
  // pending embed never changes and nothing anywhere records why. Whatever
  // else breaks, the user gets an answer and the journal gets a reason.
  const stallWatchdog = setTimeout(() => {
    if (terminalUpdateSent) return;
    logBot(
      "Lune Stall",
      `${executionId} produced no terminal update after ${localTimeoutForSelection(selected) + TERMINAL_UPDATE_GRACE_MS}ms; forcing an error reply`,
    );
    const stalled = getSession(token);
    if (!stalled) return;
    Promise.resolve(
      stalled.responder.fail(
        new Error("Run stalled: the sandbox never reported a result."),
        stalled.responder.link?.(),
      ),
    ).catch(() => {});
  }, localTimeoutForSelection(selected) + TERMINAL_UPDATE_GRACE_MS);
  stallWatchdog.unref?.();
  const controller = new AbortController();
  const runState = {
    controller,
    actorKey,
    pendingInputs: [],
    sendInput: null,
    sendProtocolMessage: null,
  };
  localRunControllers.set(token, runState);
  const fileMap = new Map();
  let liveUpdateTimer = null;
  let liveDelivery = Promise.resolve();
  let buttonDelivery = Promise.resolve();
  let lastLiveOutput = "";
  let followUp = false;
  let preserveSessionForRobloxFallback = false;

  function queueLiveUpdate(changedFileName = null) {
    const output = finishOutput(lines, {}, outputLineLimit, outputCharLimit);
    const changedFile = changedFileName ? fileMap.get(changedFileName) : null;
    if (!changedFile && (!output || output === lastLiveOutput)) return;
    if (output) lastLiveOutput = output;

    liveDelivery = liveDelivery
      .then(async () => {
        const activeSession = getSession(token);
        if (!activeSession) return;
        await activeSession.responder.deliver({
          responseContent: output || " ",
          logs: changedFile?.[0],
          changedFileName,
          fileMap,
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
      isWeb: session.responder.isWeb === true,
      timeoutMs: localTimeoutForSelection(selected),
      queueIfBusy: queueLuneWhenBusy(selected),
      signal: controller.signal,
      beforeStart() {
        return localAdmissionError(actorKey);
      },
      onStarted() {
        startLocalExecutionHealth(actorKey, executionId);
      },
      onInputReady(sendInput, sendProtocolMessage) {
        runState.sendInput = sendInput;
        runState.sendProtocolMessage = sendProtocolMessage;
        for (const input of runState.pendingInputs.splice(0)) {
          sendInput(input);
        }
      },
      onHeartbeat() {
        heartbeatLocalExecution(actorKey, executionId);
      },
      onEvent(event) {
        if (event.t === "followup") {
          followUp = true;
          return;
        }
        if (event.t === "button") {
          const activeSession = getSession(token);
          if (!activeSession?.responder.updateButton) {
            lines.push(
              formatEvent({
                t: "error",
                v: "discord.button is only available for runs started from Discord",
              }),
            );
            return;
          }
          buttonDelivery = buttonDelivery
            .then(() =>
              activeSession.responder.updateButton(event, (click) => {
                runState.sendProtocolMessage?.({
                  kind: "button",
                  buttonId: click.buttonId,
                  userId: click.userId,
                  username: click.username,
                });
              }),
            )
            .catch((error) => {
              lines.push(formatEvent({ t: "error", v: error.message }));
            });
          return;
        }
        if (event.t === "file") {
          const data = Buffer.from(String(event.hex || ""), "hex");
          const changedFileName = recordLocalFile(fileMap, event.name, data);
          queueLiveUpdate(changedFileName);
          return;
        }
        lines.push(formatEvent(event));
      },
    });
    clearInterval(liveUpdateTimer);
    liveUpdateTimer = null;
    await Promise.all([liveDelivery, buttonDelivery]);

    if (result.luneBusy && !selected.classification?.forced) {
      preserveSessionForRobloxFallback = true;
      terminalUpdateSent = true;
      return false;
    }

    if (result.admissionRejected) {
      terminalUpdateSent = true;
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

    terminalUpdateSent = true;
    await session.responder.deliver({
      responseContent: finishOutput(lines, result, outputLineLimit, outputCharLimit),
      fileMap,
      isLast: true,
      runtime: (Date.now() - startedAt) / 1000,
      serverNum: "Lune",
      followUp,
    });
  } catch (error) {
    if (liveUpdateTimer) clearInterval(liveUpdateTimer);
    await Promise.all([liveDelivery, buttonDelivery]);
    logBot("Lune Run Failed", `${executionId}: ${error.message}`);
    terminalUpdateSent = true;
    session = getSession(token);
    if (session) {
      await session.responder.fail(error, session.responder.link?.());
    }
  } finally {
    clearTimeout(stallWatchdog);
    if (liveUpdateTimer) clearInterval(liveUpdateTimer);
    if (localRunControllers.get(token) === runState) {
      localRunControllers.delete(token);
    }
    finishLocalExecutionHealth(actorKey, executionId);
    releaseLocalExecution(actorKey);
    if (!preserveSessionForRobloxFallback) {
      closeSession(token);
    }
  }

  return true;
}

module.exports = {
  cancelLocalRun,
  deliverLocalInput,
  deliverLocalInputToToken,
  localTimeoutForSelection,
  queueLuneWhenBusy,
  selectRuntime,
  tryRunLocally,
};
