const fs = require("fs");

const { ENABLE_WEB, PLAYGROUND_URL } = require("../../config");
const {
  enabled,
  getSource,
  playgroundUrlFor,
  rawUrlFor,
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

// The playground only exists as a front end for this host's web API, so it can
// only load the source when that API is serving.
function playgroundActive() {
  return ENABLE_WEB && Boolean(PLAYGROUND_URL);
}

function registerSourceRoutes(app) {
  // Served as plain text from our own origin, so pin the type and forbid
  // anything the page might try to pull in.
  function sendRaw(res, entry) {
    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Content-Security-Policy", "default-src 'none'");
    res.setHeader("Content-Disposition", 'inline; filename="source.luau"');
    fs.createReadStream(entry.filePath)
      .on("error", () => {
        if (!res.headersSent) gone(res);
        else res.end();
      })
      .pipe(res);
  }

  // The id is the only thing guarding the source, so keep it out of referrers
  // and out of caches. The wildcard CORS header stays on /raw because the
  // playground is on another origin and has to fetch it.
  function lockDown(res, { cors }) {
    if (!cors) res.removeHeader("Access-Control-Allow-Origin");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Cache-Control", "private, no-store");
  }

  // A miss is still a 200 carrying runnable Luau. The playground loads the body
  // into the editor either way, and X-Source-Status is there for callers that
  // want to tell a real source from a placeholder.
  function sendMiss(res, id) {
    const reason = enabled() && wasExpired(id) ? "expired" : "unknown";
    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.status(200).send(missBody(res, reason));
  }

  app.get("/raw/:id", (req, res) => {
    lockDown(res, { cors: true });
    const { id } = req.params;
    const entry = enabled() && ID_PATTERN.test(id) ? getSource(id) : null;
    if (!entry) return sendMiss(res, id);
    sendRaw(res, entry);
  });

  app.get("/source/:id", (req, res) => {
    lockDown(res, { cors: false });
    const { id } = req.params;

    // The playground fetches the source itself, so a dead id can still open
    // there: it will show the error("EXPIRED") placeholder in the editor.
    if (playgroundActive() && ID_PATTERN.test(id)) {
      return res.redirect(302, playgroundUrlFor(id));
    }

    const entry = enabled() && ID_PATTERN.test(id) ? getSource(id) : null;
    if (!entry) return sendMiss(res, id);
    sendRaw(res, entry);
  });
}

module.exports = { registerSourceRoutes, rawUrlFor };
