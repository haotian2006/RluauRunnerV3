const os = require("os");

const { listActorBlocks } = require("../../abuse");
const { LOCAL_MAX_CONCURRENT } = require("../../config");
const { sessionBreakdown } = require("../../core/sessions");
const { client } = require("../../discord/client");
const {
  covers,
  getLoad,
  recentErrors,
  uptimeMs,
  windows,
} = require("../../metrics");
const { getMaxWorkers } = require("../../profiles");
const { storeStats } = require("../../sourceStore");
const {
  ActiveRobloxTasks,
  DispatchedTasks,
  ExecuteTasks,
  RobloxServers,
  state,
} = require("../../state");
const {
  checkAttemptRate,
  clearAttempts,
  clearSessionCookie,
  createSession,
  dropSession,
  enabled,
  hasSession,
  matchesPassword,
  setSessionCookie,
} = require("../statusAuth");

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

function formatDuration(ms) {
  const seconds = Math.floor(ms / 1000);
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const parts = [];
  if (days) parts.push(`${days}d`);
  if (days || hours) parts.push(`${hours}h`);
  parts.push(`${minutes}m`);
  return parts.join(" ");
}

function formatPercent(value) {
  return value === null ? "sampling" : `${value.toFixed(1)}%`;
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// A 24h total on a box that started an hour ago is an hour's worth. Say that
// next to the number rather than letting it read as a full day.
function windowNote(windowMs, now) {
  return covers(windowMs, now) ? "" : " (since start)";
}

function breakdown(byName) {
  const names = Object.keys(byName).sort((a, b) => byName[b] - byName[a]);
  if (!names.length) return "-";
  return names.map((name) => `${name} ${byName[name]}`).join(", ");
}

function collect(now = Date.now()) {
  const runs = windows("run", now);
  const web = windows("web", now);
  const commands = windows("command", now);
  const limited = windows("limited", now);
  const errors = windows("error", now);

  const workers = Object.values(RobloxServers);
  const memory = process.memoryUsage();
  const store = storeStats();
  const load = getLoad();
  const totalMem = os.totalmem();
  const freeMem = os.freemem();

  const discord = client?.isReady?.()
    ? {
        guilds: client.guilds.cache.size,
        memberReach: client.guilds.cache.reduce(
          (sum, guild) => sum + guild.memberCount,
          0,
        ),
      }
    : null;

  return {
    now,
    process: {
      uptimeMs: uptimeMs(now),
      node: process.version,
      platform: `${process.platform} ${os.release()}`,
      rssBytes: memory.rss,
      heapBytes: memory.heapUsed,
    },
    host: {
      cores: load.cores,
      cpuSystemPercent: load.systemPercent,
      cpuProcessPercent: load.processPercent,
      memoryTotalBytes: totalMem,
      memoryUsedBytes: totalMem - freeMem,
      uptimeMs: os.uptime() * 1000,
    },
    runs,
    web,
    commands,
    limited,
    errors,
    pool: {
      workers: workers.length,
      maxWorkers: getMaxWorkers(),
      healthy: workers.filter((worker) => worker.healthy && !worker.retiring)
        .length,
      retiring: workers.filter((worker) => worker.retiring).length,
      queued: Object.keys(ExecuteTasks).length,
      dispatched: Object.keys(DispatchedTasks).length,
      active: Object.keys(ActiveRobloxTasks).length,
      created: state.SERVERS_CREATED,
      pendingStarts: state.PendingRobloxStarts.length,
      localMaxConcurrent: LOCAL_MAX_CONCURRENT,
    },
    sessions: sessionBreakdown(),
    blocks: listActorBlocks(now),
    store,
    discord,
    recentErrors: recentErrors(20),
  };
}

function rows(stats) {
  const now = stats.now;
  const dayNote = windowNote(DAY_MS, now);
  const twoDayNote = windowNote(2 * DAY_MS, now);

  return [
    [
      "Process",
      [
        ["Uptime", formatDuration(stats.process.uptimeMs)],
        ["Node", stats.process.node],
        ["Platform", stats.process.platform],
        ["Memory (RSS)", formatBytes(stats.process.rssBytes)],
        ["Memory (heap)", formatBytes(stats.process.heapBytes)],
        ["CPU (this process)", formatPercent(stats.host.cpuProcessPercent)],
      ],
    ],
    [
      "Host",
      [
        ["Box uptime", formatDuration(stats.host.uptimeMs)],
        ["Cores", String(stats.host.cores)],
        ["CPU (all cores)", formatPercent(stats.host.cpuSystemPercent)],
        [
          "Memory",
          `${formatBytes(stats.host.memoryUsedBytes)} / ${formatBytes(stats.host.memoryTotalBytes)}`,
        ],
      ],
    ],
    [
      "Runs",
      [
        ["Last hour", String(stats.runs.hour.total)],
        [`Last 24h${dayNote}`, String(stats.runs.day.total)],
        [`Last 48h${twoDayNote}`, String(stats.runs.twoDay.total)],
        ["By source (24h)", breakdown(stats.runs.day.byName)],
      ],
    ],
    [
      "Live now",
      [
        ["Sessions", String(stats.sessions.total)],
        [
          "Web sessions",
          `${stats.sessions.web} (${stats.sessions.webStream} sse, ${stats.sessions.webPoll} polling)`,
        ],
        ["Discord sessions", String(stats.sessions.discord)],
        [
          "Roblox workers",
          `${stats.pool.workers} / ${stats.pool.maxWorkers} (${stats.pool.healthy} healthy)`,
        ],
        ["Roblox tasks running", String(stats.pool.active)],
        ["Tasks queued", String(stats.pool.queued)],
      ],
    ],
    [
      "Discord",
      [
        ["Guilds", stats.discord ? String(stats.discord.guilds) : "not ready"],
        [
          "Member reach",
          stats.discord ? String(stats.discord.memberReach) : "not ready",
        ],
        [`Commands (24h)${dayNote}`, String(stats.commands.day.total)],
        ["By command (24h)", breakdown(stats.commands.day.byName)],
      ],
    ],
    [
      "Web API",
      [
        [`Requests (24h)${dayNote}`, String(stats.web.day.total)],
        ["By endpoint (24h)", breakdown(stats.web.day.byName)],
        [`Rate limited (24h)${dayNote}`, String(stats.limited.day.total)],
        ["By limiter (24h)", breakdown(stats.limited.day.byName)],
      ],
    ],
    [
      "Worker pool",
      [
        ["Workers", `${stats.pool.workers} / ${stats.pool.maxWorkers}`],
        ["Healthy", String(stats.pool.healthy)],
        ["Retiring", String(stats.pool.retiring)],
        ["Tasks queued", String(stats.pool.queued)],
        ["Tasks dispatched", String(stats.pool.dispatched)],
        ["Tasks active", String(stats.pool.active)],
        ["Servers created", String(stats.pool.created)],
        ["Pending starts", String(stats.pool.pendingStarts)],
        ["Lune max concurrent", String(stats.pool.localMaxConcurrent)],
      ],
    ],
    [
      "Source store",
      [
        ["Entries", String(stats.store.entries)],
        [
          "On disk",
          `${formatBytes(stats.store.bytes)} / ${formatBytes(stats.store.budgetBytes)}`,
        ],
      ],
    ],
    [
      "Blocks",
      stats.blocks.length
        ? stats.blocks.map((block) => [
            block.actorKey,
            `${Math.ceil(block.remainingMs / 1000)}s left, step ${block.step}`,
          ])
        : [["Blocked actors", "none"]],
    ],
    [
      "Errors",
      [
        [`Last hour`, String(stats.errors.hour.total)],
        [`Last 24h${dayNote}`, String(stats.errors.day.total)],
        ["By category (24h)", breakdown(stats.errors.day.byName)],
      ],
    ],
  ];
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const STYLE = `
  body { font: 13px ui-monospace, Menlo, Consolas, monospace; margin: 24px;
         color: #111; background: #fff; }
  h1 { font-size: 15px; margin: 0 0 4px; }
  h2 { font-size: 13px; margin: 20px 0 6px; text-transform: uppercase;
       letter-spacing: .06em; color: #666; font-weight: 600; }
  .meta { color: #666; margin-bottom: 4px; }
  table { border-collapse: collapse; width: 100%; max-width: 760px; }
  td { padding: 3px 12px 3px 0; vertical-align: top; border-bottom: 1px solid #eee; }
  td.k { width: 200px; color: #444; }
  td.v { text-align: right; width: 1%; white-space: nowrap; }
  td.wide { text-align: left; white-space: normal; }
  ul { margin: 0; padding-left: 18px; }
  li { margin: 2px 0; color: #444; }
  form { margin-top: 12px; }
  input { font: inherit; padding: 5px; width: 240px; }
  button { font: inherit; padding: 5px 10px; }
  .err { color: #a00; }
  @media (prefers-color-scheme: dark) {
    body { color: #ddd; background: #111; }
    h2 { color: #999; }
    td { border-bottom-color: #262626; }
    td.k, li { color: #aaa; }
    input, button { background: #1c1c1c; color: #ddd; border: 1px solid #333; }
    .err { color: #f66; }
  }
`;

function page(title, body) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<style>${STYLE}</style></head>
<body>${body}</body></html>`;
}

function loginPage(message) {
  return page(
    "Status",
    `<h1>Status</h1>
<p class="meta">This page is restricted.</p>
${message ? `<p class="err">${escapeHtml(message)}</p>` : ""}
<form method="post" action="/status/login">
  <input type="password" name="password" placeholder="Password" autofocus
         autocomplete="current-password">
  <button type="submit">Sign in</button>
</form>`,
  );
}

function statusPage(stats) {
  const sections = rows(stats)
    .map(([heading, entries]) => {
      const body = entries
        .map(
          ([key, value]) =>
            `<tr><td class="k">${escapeHtml(key)}</td>` +
            `<td class="v${String(value).length > 28 ? " wide" : ""}">${escapeHtml(value)}</td></tr>`,
        )
        .join("");
      return `<h2>${escapeHtml(heading)}</h2><table>${body}</table>`;
    })
    .join("");

  const errors = stats.recentErrors.length
    ? `<h2>Recent errors</h2><ul>${stats.recentErrors
        .map(
          (error) =>
            `<li>${escapeHtml(new Date(error.at).toISOString())} ` +
            `[${escapeHtml(error.name)}] ${escapeHtml(error.message)}</li>`,
        )
        .join("")}</ul>`
    : "";

  return page(
    "Status",
    `<h1>Status</h1>
<p class="meta">${escapeHtml(new Date(stats.now).toISOString())} &middot;
 up ${escapeHtml(formatDuration(stats.process.uptimeMs))} &middot;
 <a href="/status?format=json">json</a> &middot;
 <a href="/status/logout">sign out</a></p>
${sections}${errors}`,
  );
}

function registerStatusRoutes(app) {
  if (!enabled()) return;

  // The page is not for anyone else's origin, and must never be cached by
  // something in between.
  function lockDown(res) {
    res.removeHeader("Access-Control-Allow-Origin");
    res.setHeader("Cache-Control", "private, no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader(
      "Content-Security-Policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
    );
  }

  function sendHtml(res, status, html) {
    res.status(status).type("html").send(html);
  }

  app.get("/status", (req, res) => {
    lockDown(res);
    if (!hasSession(req)) return sendHtml(res, 401, loginPage(null));

    const stats = collect();
    if (req.query?.format === "json") return res.json(stats);
    sendHtml(res, 200, statusPage(stats));
  });

  app.post("/status/login", (req, res) => {
    lockDown(res);

    const rate = checkAttemptRate(req.ip);
    if (!rate.allowed) {
      return sendHtml(
        res,
        429,
        loginPage(
          `Too many attempts. Try again in ${Math.ceil(rate.remainingMs / 60000)} minutes.`,
        ),
      );
    }

    const password = req.body?.password;
    if (!matchesPassword(password)) {
      return sendHtml(res, 401, loginPage("Incorrect password."));
    }

    clearAttempts(req.ip);
    setSessionCookie(req, res, createSession());
    res.redirect(303, "/status");
  });

  app.get("/status/logout", (req, res) => {
    lockDown(res);
    dropSession(req);
    clearSessionCookie(res);
    sendHtml(res, 200, loginPage("Signed out."));
  });
}

module.exports = { collect, formatBytes, formatDuration, registerStatusRoutes };
