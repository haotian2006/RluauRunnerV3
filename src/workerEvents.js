// GET /workerEvents: an SSE stream that wakes workers on a queued "task" or "input".

const PING_MS = 20000;

const streams = new Set();

function notifyWorkers(event) {
  for (const res of streams) res.write(`event: ${event}\ndata: {}\n\n`);
}

function openWorkerStream(req, res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });
  res.write(": open\n\n");
  streams.add(res);
  const ping = setInterval(() => res.write(": ping\n\n"), PING_MS);
  // The response's "close" is the connection ending; the request's can come once it is read.
  res.on("close", () => {
    clearInterval(ping);
    streams.delete(res);
  });
}

module.exports = { notifyWorkers, openWorkerStream };
