const { safeMessage } = require("../sanitize");

const PING_INTERVAL_MS = 20000;

const ATTACH_DEADLINE_MS = 10000;

const OUTPUT_CHAR_LIMIT = 100000;

function sendSSE(res, event, data) {
  if (!res || res.writableEnded) return;
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

/**
 * @param {(reason?: string) => void} [onClose]
 * @param {{ requireStream?: boolean }} [options] `requireStream: false` serves a
 *   polling client: the run proceeds with no socket, and every update lands in
 *   the snapshot for `GET /result/:token` to read.
 */
function createSseResponder(onClose, options = {}) {
  const requireStream = options.requireStream !== false;
  let stream = null;
  let ping = null;
  let closed = false;
  let markReady;
  let readySettled = false;
  let attachTimer = null;
  const ready = new Promise((resolve) => {
    markReady = resolve;
  });

  // The last state the caller was told about, kept whether or not anyone is
  // listening. `content` is cumulative - every deliver carries the whole output
  // so far - so the newest one is the whole answer.
  const snapshot = {
    status: "running",
    content: "",
    runtime: 0,
    serverNum: null,
    file: null,
    error: null,
    updatedAt: Date.now(),
  };

  function touch(fields) {
    Object.assign(snapshot, fields, { updatedAt: Date.now() });
  }

  function settleReady(attached) {
    if (readySettled) return;
    readySettled = true;
    if (attachTimer) {
      clearTimeout(attachTimer);
      attachTimer = null;
    }
    markReady(attached);
  }

  function close(reason) {
    if (closed) return;
    closed = true;
    if (snapshot.status === "running") {
      touch({ status: "closed", error: reason || null });
    }
    settleReady(false);
    if (ping) clearInterval(ping);
    if (stream && !stream.writableEnded) {
      if (reason) sendSSE(stream, "error", { message: reason });
      stream.end();
    }
    stream = null;
    onClose?.(reason);
  }

  return {
    isWeb: true,
    mode: requireStream ? "sse" : "poll",
    outputCharLimit: OUTPUT_CHAR_LIMIT,

    snapshot() {
      return { ...snapshot };
    },

    attach(res) {
      stream = res;
      settleReady(true);
      ping = setInterval(() => {
        if (res.writableEnded) {
          clearInterval(ping);
          return;
        }
        res.write(": ping\n\n");
      }, PING_INTERVAL_MS);
      res.on("close", () => close());
    },

    hasStream() {
      if (!requireStream) return true;
      return !!stream && !stream.writableEnded && !stream.destroyed;
    },

    waitUntilReady() {
      if (!requireStream) return Promise.resolve(true);
      if (!readySettled && !attachTimer) {
        attachTimer = setTimeout(() => settleReady(false), ATTACH_DEADLINE_MS);
        attachTimer.unref?.();
      }
      return ready;
    },

    async deliver({
      responseContent,
      fileMap,
      changedFileName,
      isLast,
      runtime,
      serverNum,
    }) {
      let file = null;
      if (fileMap && changedFileName && fileMap.has(changedFileName)) {
        const [data, fileType, fileName] = fileMap.get(changedFileName);
        file = {
          name: `${fileName}.${fileType}`,
          type: fileType,
          content: data.toString("base64"),
        };
      }

      touch({
        status: isLast ? "done" : "running",
        content: responseContent,
        runtime,
        serverNum,
        ...(file ? { file } : {}),
      });

      if (!stream) {
        // Nothing left to push the run along once it is over, so a polling
        // session tears itself down here instead of waiting for the timeout.
        if (isLast) close();
        return;
      }

      sendSSE(stream, "output", {
        content: responseContent,
        isLast: !!isLast,
        runtime,
        serverNum,
      });

      if (file) {
        sendSSE(stream, "file", file);
      }

      if (isLast) {
        sendSSE(stream, "done", { runtime });
        stream.end();
      }
    },

    async fail(error) {
      const message = safeMessage(error);
      touch({ status: "error", error: message });
      if (!stream) {
        close();
        return;
      }
      sendSSE(stream, "error", { message });
      stream.end();
    },

    close,
  };
}

module.exports = { sendSSE, createSseResponder };
