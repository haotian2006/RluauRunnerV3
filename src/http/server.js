const express = require("express");

const { BODY_LIMIT, PORT } = require("../config");
const { registerButtonRoutes } = require("./routes/buttons");
const { registerRespondRoutes } = require("./routes/respond");
const { registerSessionRoutes } = require("./routes/session");

const app = express();

app.use(express.json({ limit: BODY_LIMIT }));

registerRespondRoutes(app);
registerButtonRoutes(app);
registerSessionRoutes(app);

function start() {
  return app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server is running on port ${PORT}`);
  });
}

module.exports = { start };
