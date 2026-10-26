const { ImportError, importModel, importTree } = require("../../github/import");
const { parseRobloxTarget } = require("../../github/roblox");
const { logBot } = require("../../log");
const { limiterKey } = require("../../origin");
const { checkToolRate } = require("../../web/rateLimit");
const { requireSecret } = require("../middleware");

// Public Roblox imports are cache misses on the bot's Open Cloud key, so keep them few.
const ROBLOX_IMPORT_RATE_LIMIT = 20;

function registerGithubRoutes(app) {
  // Worker-only, like /asset: the bot does the downloading and building for io.import.
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

  // For the playground, which builds GitHub and Wally imports itself but can't hold the
  // Open Cloud key: ?format=tree gives its JSON nodes, anything else the .rbxm.
  app.get("/import/roblox/:id", async (req, res) => {
    let target;
    try {
      target = parseRobloxTarget(req.params.id);
    } catch (err) {
      if (!(err instanceof ImportError)) throw err;
      return res.status(err.status).json({ message: err.message });
    }
    if (!target) return res.status(400).json({ message: "Invalid asset id" });
    if (!checkToolRate(limiterKey(req), "robloxImport", ROBLOX_IMPORT_RATE_LIMIT)) {
      return res.status(429).json({ message: `Rate limit: max ${ROBLOX_IMPORT_RATE_LIMIT} asset imports/min` });
    }
    const tree = req.query.format === "tree";
    try {
      const bytes = await (tree ? importTree : importModel)(target.id);
      res.setHeader("X-Content-Type-Options", "nosniff");
      if (tree) {
        res.setHeader("Content-Type", "application/json");
      } else {
        res.setHeader("Content-Type", "application/octet-stream");
        res.setHeader("Content-Disposition", `attachment; filename="Asset${target.id}.rbxm"`);
      }
      res.send(bytes);
    } catch (err) {
      if (err instanceof ImportError) {
        return res.status(err.status).json({ message: err.message });
      }
      logBot("Roblox Import", `${target.id} failed: ${err.message}`);
      res.status(502).json({ message: "Asset download failed" });
    }
  });
}

module.exports = { registerGithubRoutes };
