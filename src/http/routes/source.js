const { ENABLE_WEB, PLAYGROUND_URL } = require("../../config");
const { logBot } = require("../../log");
const {
  enabled,
  getSource,
  playgroundUrlFor,
  rawUrlFor,
  readSource,
  wasExpired,
} = require("../../sourceStore");

const ID_PATTERN = /^[0-9a-fA-F-]{1,64}$/;

// The playground drops whatever comes back straight into its editor, so a miss
// answers in Luau instead of prose: the user sees why when they hit run.
const EXPIRED_SOURCE = 'error("EXPIRED")';
const UNKNOWN_SOURCE = 'error("DOES NOT EXIST")';

function missBody(res, reason) {
  res.setHeader("X-Source-Status", reason);
  return reason === "expired" ? EXPIRED_SOURCE : UNKNOWN_SOURCE;
}

function playgroundActive() {
  return ENABLE_WEB && Boolean(PLAYGROUND_URL);
}

function registerSourceRoutes(app) {
  async function sendRaw(res, entry, id) {
    let source;
    try {
      source = await readSource(entry);
    } catch (err) {
      // Swept or truncated between lookup and read; answer like an expired id.
      logBot("Source Store", `failed to read ${entry.id}: ${err.message}`);
      return sendMiss(res, id);
    }
    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Content-Security-Policy", "default-src 'none'");
    res.setHeader("Content-Disposition", 'inline; filename="source.luau"');
    res.send(source);
  }

  // The id is the only guard, so no referrer or caching. Wildcard CORS stays on /raw
  // because the playground fetches it from another origin.
  function lockDown(res, { cors }) {
    if (!cors) res.removeHeader("Access-Control-Allow-Origin");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Cache-Control", "private, no-store");
  }

  // A miss is still a 200 with runnable Luau for the editor; X-Source-Status tells them apart.
  function sendMiss(res, id) {
    const reason = enabled() && wasExpired(id) ? "expired" : "unknown";
    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.status(200).send(missBody(res, reason));
  }

  app.get("/raw/:id", async (req, res) => {
    lockDown(res, { cors: true });
    const { id } = req.params;
    const entry = enabled() && ID_PATTERN.test(id) ? getSource(id) : null;
    if (!entry) return sendMiss(res, id);
    await sendRaw(res, entry, id);
  });

  app.get("/source/:id", async (req, res) => {
    lockDown(res, { cors: false });
    const { id } = req.params;

    // Redirect even dead ids; the playground shows the error("EXPIRED") placeholder.
    if (playgroundActive() && ID_PATTERN.test(id)) {
      return res.redirect(302, playgroundUrlFor(id));
    }

    const entry = enabled() && ID_PATTERN.test(id) ? getSource(id) : null;
    if (!entry) return sendMiss(res, id);
    await sendRaw(res, entry, id);
  });
}

module.exports = { registerSourceRoutes, rawUrlFor };
