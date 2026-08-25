const PING_INTERVAL_MS = 20000;

function sendSSE(res, event, data) {
  if (!res || res.writableEnded) return;
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function createSseResponder(onClose) {
  let stream = null;
  let ping = null;
  let closed = false;

  return {
    attach(res) {
      stream = res;
      ping = setInterval(() => {
        if (res.writableEnded) {
          clearInterval(ping);
          return;
        }
        res.write(": ping\n\n");
      }, PING_INTERVAL_MS);
      res.on("close", () => clearInterval(ping));
    },

    hasStream() {
      return !!stream && !stream.writableEnded;
    },

    async deliver({ responseContent, fileMap, isLast, runtime, serverNum }) {
      if (!stream) return;

      sendSSE(stream, "output", {
        content: responseContent,
        isLast: !!isLast,
        runtime,
        serverNum,
      });

      if (fileMap) {
        for (const [, [data, fileType, fileName]] of fileMap) {
          sendSSE(stream, "file", {
            name: `${fileName}.${fileType}`,
            type: fileType,
            content: data.toString("base64"),
          });
        }
      }

      if (isLast) {
        sendSSE(stream, "done", { runtime });
        stream.end();
      }
    },

    async fail(error) {
      if (!stream) return;
      sendSSE(stream, "error", { message: error.message });
      stream.end();
    },

    close(reason) {
      if (closed) return;
      closed = true;
      if (ping) clearInterval(ping);
      if (stream && !stream.writableEnded) {
        if (reason) sendSSE(stream, "error", { message: reason });
        stream.end();
      }
      stream = null;
      onClose?.(reason);
    },
  };
}

module.exports = { sendSSE, createSseResponder };
