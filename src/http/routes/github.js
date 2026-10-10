const { ImportError, importModel } = require("../../github/import");
const { logBot } = require("../../log");
const { requireSecret } = require("../middleware");

function registerGithubRoutes(app) {
  // Worker-only, like /asset: the bot does the downloading and building for misc.import.
  app.get("/github", requireSecret, async (req, res) => {
    const url = req.query.url;
    if (typeof url !== "string" || url.length > 2048) {
      return res.status(400).json({ message: "Missing url" });
    }
    try {
      const bytes = await importModel(url);
      res.setHeader("Content-Type", "application/octet-stream");
      res.send(bytes);
    } catch (err) {
      if (err instanceof ImportError) {
        return res.status(err.status).json({ message: err.message });
      }
      logBot("GitHub Import", `${url} failed: ${err.message}`);
      res.status(502).json({ message: "GitHub download failed" });
    }
  });
}

module.exports = { registerGithubRoutes };
