const { safeMessage } = require("../sanitize");

const PING_INTERVAL_MS = 20000;

const ATTACH_DEADLINE_MS = 10000;

const OUTPUT_CHAR_LIMIT = 100000;

function sendSSE(res, event, data) {
  if (!res || res.writableEnded) return;
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function createSseResponder(onClose) {
  let stream = null;
  let ping = null;
  let closed = false;
  let markReady;
  let readySettled = false;
  let attachTimer = null;
  const ready = new Promise((resolve) => {
    markReady = resolve;
  });

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
    outputCharLimit: OUTPUT_CHAR_LIMIT,

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
      return !!stream && !stream.writableEnded && !stream.destroyed;
    },

    waitUntilReady() {
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
      if (!stream) return;

      sendSSE(stream, "output", {
        content: responseContent,
        isLast: !!isLast,
        runtime,
        serverNum,
      });

      if (fileMap && changedFileName && fileMap.has(changedFileName)) {
        const [data, fileType, fileName] = fileMap.get(changedFileName);
        sendSSE(stream, "file", {
          name: `${fileName}.${fileType}`,
          type: fileType,
          content: data.toString("base64"),
        });
      }

      if (isLast) {
        sendSSE(stream, "done", { runtime });
        stream.end();
      }
    },

    async fail(error) {
      if (!stream) return;
      sendSSE(stream, "error", { message: safeMessage(error) });
      stream.end();
    },

    close,
  };
}

module.exports = { sendSSE, createSseResponder };
