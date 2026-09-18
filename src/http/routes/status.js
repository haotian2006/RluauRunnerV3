const crypto = require("crypto");
const os = require("os");

const { listActorBlocks } = require("../../abuse");
const { LOCAL_MAX_CONCURRENT } = require("../../config");
const { sessionBreakdown } = require("../../core/sessions");
const { client } = require("../../discord/client");
const {
  covers,
  getLoad,
  histogram,
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
// Servers the page lists before it stops and says how many are left. The JSON
// view carries all of them.
const GUILD_ROWS = 25;
const REFRESH_SECONDS = 1;
const CHART_BUCKETS = 24;

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

  // Server metadata the gateway already handed us, largest first. Held in
  // memory only - never written to disk or to the log - and shown behind the
  // login, never on the public /stats.
  const discord = client?.isReady?.()
    ? {
        guilds: client.guilds.cache.size,
        memberReach: client.guilds.cache.reduce(
          (sum, guild) => sum + guild.memberCount,
          0,
        ),
        guildList: [...client.guilds.cache.values()]
          .map((guild) => ({
            id: guild.id,
            name: guild.name,
            memberCount: guild.memberCount,
          }))
          .sort((a, b) => b.memberCount - a.memberCount),
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
    charts: {
      runsPerHour: histogram("run", HOUR_MS, CHART_BUCKETS, now),
      webPerHour: histogram("web", HOUR_MS, CHART_BUCKETS, now),
      cpu: load.history,
    },
    sessions: sessionBreakdown(),
    blocks: listActorBlocks(now),
    store,
    discord,
    recentErrors: recentErrors(20),
  };
}

function guildRows(discord) {
  if (!discord) return [["Servers", "bot not ready"]];
  if (!discord.guildList.length) return [["Servers", "none"]];

  const shown = discord.guildList.slice(0, GUILD_ROWS);
  const listed = shown.map((guild) => [
    guild.name,
    `${guild.memberCount} members`,
  ]);
  if (discord.guildList.length > shown.length) {
    listed.push([
      `+${discord.guildList.length - shown.length} more`,
      "see ?format=json",
    ]);
  }
  return listed;
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
      "Servers",
      guildRows(stats.discord),
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

// --- charts -----------------------------------------------------------------
// Server-rendered SVG: the page ships no script, so the marks are drawn here
// and the only interaction is the native tooltip an SVG <title> gives for free.

const CHART_WIDTH = 720;
const CHART_HEIGHT = 96;
const BAR_GAP = 2;
const BAR_RADIUS = 4;

/** A bar whose top corners are rounded and whose base sits on the axis. */
function barPath(x, y, width, height) {
  const base = y + height;
  if (height <= BAR_RADIUS) {
    return `M${x} ${base}h${width}v${-height}h${-width}z`;
  }
  const r = Math.min(BAR_RADIUS, width / 2);
  return (
    `M${x} ${base}V${y + r}Q${x} ${y} ${x + r} ${y}` +
    `H${x + width - r}Q${x + width} ${y} ${x + width} ${y + r}V${base}Z`
  );
}

function barChart(series, { label, describe }) {
  const max = Math.max(1, ...series.map((point) => point.count));
  const width =
    (CHART_WIDTH - BAR_GAP * (series.length - 1)) / series.length;
  const plotHeight = CHART_HEIGHT - 18;

  const bars = series
    .map((point, index) => {
      const height = (point.count / max) * plotHeight;
      const x = index * (width + BAR_GAP);
      const y = plotHeight - height;
      const title = `<title>${escapeHtml(describe(point))}</title>`;
      if (point.count === 0) {
        // An empty bucket still needs a hit target, and a hairline reads as
        // "measured, nothing happened" rather than "no data".
        return `<g>${title}<rect x="${x.toFixed(1)}" y="${plotHeight - 1}" width="${width.toFixed(1)}" height="1" class="empty"/></g>`;
      }
      return `<g>${title}<path d="${barPath(x, y, width, height)}"/></g>`;
    })
    .join("");

  // Selective labels only: the ends and the middle, never one per bar.
  const ticks = [0, Math.floor(series.length / 2), series.length - 1]
    .map((index) => {
      const x = index * (width + BAR_GAP) + width / 2;
      const anchor =
        index === 0 ? "start" : index === series.length - 1 ? "end" : "middle";
      const hours = series.length - index - 1;
      const text = hours === 0 ? "now" : `-${hours}h`;
      return `<text x="${x.toFixed(1)}" y="${CHART_HEIGHT - 4}" text-anchor="${anchor}" class="tick">${text}</text>`;
    })
    .join("");

  return `<figure class="chart">
<figcaption>${escapeHtml(label)} <span class="peak">peak ${max}/h</span></figcaption>
<svg viewBox="0 0 ${CHART_WIDTH} ${CHART_HEIGHT}" width="100%" height="${CHART_HEIGHT}"
     role="img" aria-label="${escapeHtml(label)}, peak ${max} per hour">
<g class="bars">${bars}</g>
<line x1="0" y1="${plotHeight}" x2="${CHART_WIDTH}" y2="${plotHeight}" class="axis"/>
${ticks}
</svg></figure>`;
}

function sparkline(history, { label }) {
  if (history.length < 2) {
    return `<figure class="chart"><figcaption>${escapeHtml(label)}</figcaption>
<p class="meta">sampling</p></figure>`;
  }
  const height = 48;
  const points = history.map((sample, index) => {
    const x = (index / (history.length - 1)) * CHART_WIDTH;
    const y = height - (Math.min(100, sample.system) / 100) * height;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const latest = history[history.length - 1].system;

  return `<figure class="chart">
<figcaption>${escapeHtml(label)} <span class="peak">now ${latest.toFixed(1)}%</span></figcaption>
<svg viewBox="0 0 ${CHART_WIDTH} ${height}" width="100%" height="${height}"
     role="img" aria-label="${escapeHtml(label)}, currently ${latest.toFixed(1)} percent">
<polyline points="${points.join(" ")}" class="spark"/>
</svg></figure>`;
}

function chartsFor(stats) {
  const hourOf = (point) =>
    new Date(point.at).toLocaleTimeString([], { hour: "2-digit" });
  return (
    barChart(stats.charts.runsPerHour, {
      label: "Runs per hour",
      describe: (point) => `${hourOf(point)}: ${point.count} runs`,
    }) +
    barChart(stats.charts.webPerHour, {
      label: "Web requests per hour",
      describe: (point) => `${hourOf(point)}: ${point.count} requests`,
    }) +
    sparkline(stats.charts.cpu, { label: "CPU, last 10 minutes" })
  );
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
  figure.chart { margin: 0 0 18px; max-width: 760px; }
  figcaption { color: #666; margin-bottom: 4px; }
  .peak { color: #999; }
  .bars path { fill: var(--series); }
  .bars rect.empty { fill: #d8d8d8; }
  .axis { stroke: #e3e3e3; stroke-width: 1; }
  .tick { fill: #999; font-size: 10px; font-family: inherit; }
  .spark { fill: none; stroke: var(--series); stroke-width: 2;
           stroke-linejoin: round; stroke-linecap: round; }
  :root { --series: #2a78d6; }
  @media (prefers-color-scheme: dark) {
    body { color: #ddd; background: #111; }
    h2 { color: #999; }
    td { border-bottom-color: #262626; }
    td.k, li { color: #aaa; }
    input, button { background: #1c1c1c; color: #ddd; border: 1px solid #333; }
    .err { color: #f66; }
    figcaption { color: #999; }
    .peak { color: #777; }
    .axis { stroke: #333; }
    .bars rect.empty { fill: #3a3a3a; }
    /* Stepped for the dark surface, not an inverted light value. */
    :root { --series: #3987e5; }
  }
`;

function page(title, body, { noScriptRefresh = false } = {}) {
  // Only for a browser with script off: a slow whole-page reload, which is the
  // behaviour the in-place updater exists to avoid.
  const fallback = noScriptRefresh
    ? `<noscript><meta http-equiv="refresh" content="10"></noscript>`
    : "";
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">${fallback}
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

/**
 * Every live value on the page, addressed by a stable key. The page renders
 * from this and the updater rewrites from it, so the two can never disagree
 * about what a cell should say.
 */
function liveValues(stats) {
  const values = {};
  rows(stats).forEach(([heading, entries], section) => {
    entries.forEach(([label, value], index) => {
      values[`${section}.${index}`] = { label, value: String(value) };
    });
  });
  values.head = {
    label: "head",
    value:
      `${new Date(stats.now).toISOString()} · up ` +
      `${formatDuration(stats.process.uptimeMs)}`,
  };
  return values;
}

function errorList(stats) {
  if (!stats.recentErrors.length) return "";
  return `<h2>Recent errors</h2><ul id="errors">${stats.recentErrors
    .map(
      (error) =>
        `<li>${escapeHtml(new Date(error.at).toISOString())} ` +
        `[${escapeHtml(error.name)}] ${escapeHtml(error.message)}</li>`,
    )
    .join("")}</ul>`;
}

// Patches only the cells whose text actually changed, so a selection anywhere
// else on the page survives - which a whole-document reload cannot do.
const UPDATE_SCRIPT = `
(function () {
  var timer = null;
  function apply(data) {
    for (var key in data.values) {
      var cell = document.querySelector('[data-k="' + key + '"]');
      if (!cell) continue;
      var next = data.values[key].value;
      if (cell.textContent !== next) cell.textContent = next;
    }
    var head = document.getElementById("head");
    if (head && data.values.head && head.textContent !== data.values.head.value) {
      head.textContent = data.values.head.value;
    }
    var charts = document.getElementById("charts");
    if (charts && data.charts && charts.innerHTML !== data.charts) {
      charts.innerHTML = data.charts;
    }
    var errors = document.getElementById("errors");
    if (errors && data.errors !== null && errors.innerHTML !== data.errors) {
      errors.innerHTML = data.errors;
    }
  }
  var ticks = 0;
  function tick() {
    // The charts are most of the payload and move slowly, so they ride along
    // once every five seconds rather than every second.
    var wantCharts = ticks++ % 5 === 0;
    fetch("/status/data" + (wantCharts ? "?charts=1" : ""), { credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { location.reload(); return null; }
        return r.ok ? r.json() : null;
      })
      .then(function (data) { if (data) apply(data); })
      .catch(function () {})
      .then(function () { timer = setTimeout(tick, ${REFRESH_SECONDS * 1000}); });
  }
  // Nothing to update while the tab is in the background.
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { clearTimeout(timer); }
    else if (!document.hidden) { clearTimeout(timer); tick(); }
  });
  tick();
})();
`;

function statusPage(stats, nonce) {
  const values = liveValues(stats);
  const sections = rows(stats)
    .map(([heading, entries], section) => {
      const body = entries
        .map(([label, value], index) => {
          const key = `${section}.${index}`;
          const wide = String(value).length > 28 ? " wide" : "";
          return (
            `<tr><td class="k">${escapeHtml(label)}</td>` +
            `<td class="v${wide}" data-k="${key}">${escapeHtml(String(value))}</td></tr>`
          );
        })
        .join("");
      return `<h2>${escapeHtml(heading)}</h2><table>${body}</table>`;
    })
    .join("");

  return page(
    "Status",
    `<h1>Status</h1>
<p class="meta"><span id="head">${escapeHtml(values.head.value)}</span> &middot;
 <a href="/status?format=json">json</a> &middot;
 <a href="/status/logout">sign out</a></p>
<div id="charts">${chartsFor(stats)}</div>${sections}${errorList(stats)}
<script nonce="${nonce}">${UPDATE_SCRIPT}</script>`,
    { noScriptRefresh: true },
  );
}

function registerStatusRoutes(app) {
  if (!enabled()) return;

  // The page is not for anyone else's origin, and must never be cached by
  // something in between.
  // `nonce` is per response, so only the updater this server just wrote can
  // run - an injected <script> still has nothing to quote.
  function lockDown(res, nonce = null) {
    res.removeHeader("Access-Control-Allow-Origin");
    res.setHeader("Cache-Control", "private, no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader(
      "Content-Security-Policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'" +
        (nonce ? `; script-src 'nonce-${nonce}'; connect-src 'self'` : ""),
    );
  }

  function sendHtml(res, status, html) {
    res.status(status).type("html").send(html);
  }

  app.get("/status", (req, res) => {
    const nonce = crypto.randomBytes(16).toString("base64");
    lockDown(res, nonce);
    if (!hasSession(req)) return sendHtml(res, 401, loginPage(null));

    const stats = collect();
    if (req.query?.format === "json") return res.json(stats);
    sendHtml(res, 200, statusPage(stats, nonce));
  });

  // What the page polls: the same values it was rendered from, plus the
  // freshly drawn charts. Session-gated like everything else here.
  app.get("/status/data", (req, res) => {
    lockDown(res);
    if (!hasSession(req)) {
      return res.status(401).json({ error: "Not signed in" });
    }
    const stats = collect();
    res.json({
      values: liveValues(stats),
      charts: req.query?.charts ? chartsFor(stats) : null,
      errors: errorList(stats)
        ? errorList(stats).replace(/^[\s\S]*?<ul id="errors">|<\/ul>$/g, "")
        : null,
    });
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
