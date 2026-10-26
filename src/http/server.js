const express = require("express");
const fs = require("fs");
const http = require("http");

const {
  BODY_LIMIT,
  ENABLE_WEB,
  PORT,
  WORKER_SECRET_FILE,
  WORKER_SOCKET,
} = require("../config");
const { startDataStoreSweeps } = require("../dataStores");
const { SECRET_TOKEN } = require("../state");
const { registerAssetRoutes } = require("./routes/assets");
const { registerButtonRoutes } = require("./routes/buttons");
const { registerDataStoreRoutes } = require("./routes/dataStores");
const { registerGithubRoutes } = require("./routes/github");
const { registerRespondRoutes } = require("./routes/respond");
const { registerSessionRoutes } = require("./routes/session");
const { registerSourceRoutes } = require("./routes/source");
const { registerStatusRoutes } = require("./routes/status");
const { registerWebRoutes } = require("../web");

const app = express();

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.use(express.json({ limit: BODY_LIMIT }));
// Only the status login posts a form; keep it small so it can't bypass the JSON limit.
app.use(express.urlencoded({ extended: false, limit: "4kb" }));

registerRespondRoutes(app);
registerAssetRoutes(app);
registerButtonRoutes(app);
registerDataStoreRoutes(app);
registerGithubRoutes(app);
registerSessionRoutes(app);
registerSourceRoutes(app);
registerStatusRoutes(app);

if (ENABLE_WEB) {
  registerWebRoutes(app);
}

const WORKER_PATHS = new Set([
  "/start",
  "/ping",
  "/retire",
  "/getInputs",
  "/getAll",
  "/getNext",
  "/get",
  "/chunk",
  "/uploadChunk",
  "/respond",
  "/debug",
  "/button",
  "/github",
  "/workerEvents",
  "/dataStore/load",
  "/dataStore/save",
]);

function isWorkerPath(url) {
  const path = url.split("?", 1)[0];
  return WORKER_PATHS.has(path) || path.startsWith("/asset/");
}

function startWorkerSocket() {
  fs.rmSync(WORKER_SOCKET, { force: true });
  const server = http.createServer((req, res) => {
    if (!isWorkerPath(req.url)) return res.writeHead(404).end();
    // Only headless Studio workers on this host can connect here.
    req.studioWorker = true;
    app(req, res);
  });
  server.listen(WORKER_SOCKET, () => {
    fs.chmodSync(WORKER_SOCKET, 0o600);
    console.log(`Worker socket listening on ${WORKER_SOCKET}`);
    // The secret changes every start; the supervisor restarts workers when it
    // does and stops them when the file goes away with the bot.
    if (WORKER_SECRET_FILE) {
      fs.rmSync(WORKER_SECRET_FILE, { force: true });
      fs.writeFileSync(WORKER_SECRET_FILE, SECRET_TOKEN, { mode: 0o600 });
    }
  });
}

function start() {
  if (WORKER_SOCKET) startWorkerSocket();
  startDataStoreSweeps();
  return app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server is running on port ${PORT}`);
  });
}

module.exports = { isWorkerPath, start };
