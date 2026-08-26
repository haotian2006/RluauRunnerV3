const express = require("express");

const { BODY_LIMIT, ENABLE_WEB, PORT } = require("../config");
const { registerButtonRoutes } = require("./routes/buttons");
const { registerRespondRoutes } = require("./routes/respond");
const { registerSessionRoutes } = require("./routes/session");
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

registerRespondRoutes(app);
registerButtonRoutes(app);
registerSessionRoutes(app);

if (ENABLE_WEB) {
  registerWebRoutes(app);
}

function start() {
  return app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server is running on port ${PORT}`);
  });
}

module.exports = { start };
