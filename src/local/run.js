const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const {
  LOCAL_MAX_CONCURRENT,
  LOCAL_MAX_LINES,
  LOCAL_MAX_LINE_BYTES,
  LOCAL_MEMORY_LIMIT_MB,
  LOCAL_CPU_QUOTA_PERCENT,
  LOCAL_HEARTBEAT_TIMEOUT_MS,
  LOCAL_TIMEOUT_MS,
  PATH_TO_LUNE,
  ROOT_DIR,
} = require("../config");
const { parseHotComments } = require("./hotComments");
const { stripHostPaths } = require("../sanitize");

const SANDBOX_PATH = path.join(ROOT_DIR, "src", "local", "sandbox.luau");
const KILL_GRACE_MS = 1000;
const HEARTBEAT_STALE_MS = 1500;

// Capped, not unbounded: this box shares few cores with the Discord client.
let active = 0;
const waiting = [];

function acquireSlot(signal) {
  if (signal?.aborted) return Promise.resolve(false);
  if (active < LOCAL_MAX_CONCURRENT) {
    active += 1;
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const waiter = { resolve, signal, onAbort: null };
    waiter.onAbort = () => {
      const index = waiting.indexOf(waiter);
      if (index < 0) return;
      waiting.splice(index, 1);
      resolve(false);
    };
    signal?.addEventListener("abort", waiter.onAbort, { once: true });
    waiting.push(waiter);
  });
}

function releaseSlot() {
  while (waiting.length) {
    const next = waiting.shift();
    next.signal?.removeEventListener("abort", next.onAbort);
    if (next.signal?.aborted) {
      next.resolve(false);
      continue;
    }
    next.resolve(true);
    return;
  }
  active -= 1;
}

function queueDepth() {
  return waiting.length;
}

// No portable memory cap in Node. ulimit is a shell builtin, hence bash -c;
// Windows has no equivalent short of Job Objects.
function buildCommand(jobPath) {
  const args = ["run", SANDBOX_PATH, jobPath];

  let command = PATH_TO_LUNE;
  let finalArgs = args;

  if (process.platform !== "win32" && LOCAL_MEMORY_LIMIT_MB) {
    const quoted = [PATH_TO_LUNE, ...args]
      .map((part) => `'${String(part).replace(/'/g, "'\\''")}'`)
      .join(" ");
    command = "/bin/bash";
    finalArgs = ["-c", `ulimit -v ${LOCAL_MEMORY_LIMIT_MB * 1024}; exec ${quoted}`];
  }

  if (process.platform !== "win32" && LOCAL_CPU_QUOTA_PERCENT) {
    finalArgs = [
      "--scope",
      "--quiet",
      "--collect",
      "-p",
      `CPUQuota=${LOCAL_CPU_QUOTA_PERCENT}%`,
      "--",
      command,
      ...finalArgs,
    ];
    command = "systemd-run";
  }

  return { command, args: finalArgs, shell: false };
}

function isMemoryLimitAvailable() {
  return process.platform !== "win32" && Boolean(LOCAL_MEMORY_LIMIT_MB);
}

function isCpuQuotaAvailable() {
  return process.platform !== "win32" && Boolean(LOCAL_CPU_QUOTA_PERCENT);
}

/**
 * Run one script in the Lune sandbox. onEvent receives {t, v} objects, where t is the type (out, warn, error, heartbeat) and v is the value.
 */
async function runLocal(source, options = {}) {
  const {
    onEvent = () => {},
    onHeartbeat = () => {},
    onStarted = () => {},
    onInputReady = () => {},
    beforeStart = () => null,
    timeoutMs = LOCAL_TIMEOUT_MS,
    heartbeatTimeoutMs = LOCAL_HEARTBEAT_TIMEOUT_MS,
    allowCodegen = false,
    signal = null,
  } = options;

  const hot = parseHotComments(source);

  const acquired = await acquireSlot(signal);
  if (!acquired || signal?.aborted) {
    if (acquired) releaseSlot();
    return {
      ok: false,
      timedOut: false,
      cancelled: true,
      error: "Script stopped by user",
    };
  }

  let admissionError = null;
  try {
    admissionError = beforeStart();
  } catch (error) {
    admissionError = error?.message || String(error);
  }
  if (admissionError) {
    releaseSlot();
    return {
      ok: false,
      timedOut: false,
      admissionRejected: true,
      error:
        admissionError instanceof Error
          ? admissionError.message
          : String(admissionError),
    };
  }

  let command, args;
  try {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-local-"));
    const jobPath = path.join(tmpDir, "job.json");

    fs.writeFileSync(
      jobPath,
      JSON.stringify({
        source,
        optimizationLevel: hot.optimizationLevel,

        codegenEnabled: allowCodegen && hot.native,
        maxLines: LOCAL_MAX_LINES,
        maxLineBytes: LOCAL_MAX_LINE_BYTES,
      }),
      "utf8",
    );

    ({ command, args } = buildCommand(jobPath));
  } catch (error) {
    releaseSlot();
    return {
      ok: false,
      timedOut: false,
      error: error?.message || String(error),
    };
  }

  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
      child.stdin.on("error", () => {});
      try {
        onInputReady((value) => {
          if (!child.stdin.writable || child.stdin.destroyed) return false;
          const payload = Buffer.isBuffer(value)
            ? { kind: "buffer", hex: value.toString("hex") }
            : { kind: "string", value: String(value ?? "") };
          child.stdin.write(`${JSON.stringify(payload)}\n`, () => {});
          return true;
        });
      } catch {}
      try {
        onStarted();
      } catch {}
    } catch (err) {
      cleanup();
      releaseSlot();
      resolve({ ok: false, timedOut: false, error: err.message });
      return;
    }

    let stdoutBuffer = "";
    let stderr = "";
    let timedOut = false;
    let cancelled = false;
    let settled = false;
    let killTimer = null;
    let heartbeatTimer = null;
    let lastHeartbeatAt = 0;
    let timeoutKind = null;

    let scriptErrored = false;

    function terminate(reason, kind = null) {
      if (settled || timedOut || cancelled) return;
      timedOut = reason === "timeout";
      timeoutKind = timedOut ? kind : null;
      cancelled = reason === "cancelled";
      child.kill("SIGTERM");

      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
    }

    function schedulerResponsive() {
      return (
        lastHeartbeatAt > 0 &&
        Date.now() - lastHeartbeatAt <= HEARTBEAT_STALE_MS
      );
    }

    function armHeartbeatWatchdog() {
      if (heartbeatTimer) clearTimeout(heartbeatTimer);
      heartbeatTimer = setTimeout(
        () => terminate("timeout", "blocked"),
        heartbeatTimeoutMs,
      );
    }

    armHeartbeatWatchdog();
    const timer = setTimeout(
      () =>
        terminate("timeout", schedulerResponsive() ? "yielding" : "blocked"),
      timeoutMs,
    );
    const onAbort = () => terminate("cancelled");
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();

    function cleanup() {
      try {
        fs.unlinkSync(jobPath);
        fs.rmdirSync(tmpDir);
      } catch {}
    }

    function handleLine(line) {
      if (!line.trim()) return;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        onEvent({ t: "out", v: line });
        return;
      }
      if (event.t === "heartbeat") {
        lastHeartbeatAt = Date.now();
        try {
          onHeartbeat();
        } catch {}
        armHeartbeatWatchdog();
        return;
      }
      if (event.t === "error") scriptErrored = true;
      if (typeof event.v === "string") event.v = stripHostPaths(event.v);
      onEvent(event);
    }

    child.stdout.on("data", (data) => {
      stdoutBuffer += data.toString("utf-8");
      let index;
      while ((index = stdoutBuffer.indexOf("\n")) >= 0) {
        const line = stdoutBuffer.slice(0, index);
        stdoutBuffer = stdoutBuffer.slice(index + 1);
        handleLine(line);
      }
    });

    child.stderr.on("data", (data) => {
      if (stderr.length < LOCAL_MAX_LINE_BYTES * 4) {
        stderr += data.toString("utf-8");
      }
    });

    function settle(result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (heartbeatTimer) clearTimeout(heartbeatTimer);
      if (killTimer) clearTimeout(killTimer);
      signal?.removeEventListener("abort", onAbort);
      child.stdin.end();
      cleanup();
      releaseSlot();
      resolve(result);
    }

    child.on("error", (err) => {
      settle({
        ok: false,
        timedOut: false,
        error:
          err.code === "ENOENT"
            ? "lune is not installed. Run `npm run fetch-tools` to download it."
            : err.message,
      });
    });

    child.on("close", (code) => {
      if (stdoutBuffer.trim()) handleLine(stdoutBuffer);

      if (timedOut) {
        settle({
          ok: false,
          timedOut: true,
          timeoutKind,
          error:
            timeoutKind === "yielding"
              ? `Script reached its ${timeoutMs / 1000}s lifespan while yielding`
              : "Script timeout: exhausted allowed execution time",
        });
        return;
      }

      if (cancelled) {
        settle({
          ok: false,
          timedOut: false,
          cancelled: true,
          error: "Script stopped by user",
        });
        return;
      }

      // Non-zero with no stdout is usually the memory cap.
      settle({
        ok: code === 0 && !scriptErrored,
        timedOut: false,
        abnormalExit: code !== 0,
        scriptErrored,
        error:
          code === 0
            ? null
            : stripHostPaths(stderr.trim()) || `Sandbox exited with ${code}`,
      });
    });
  });
}

module.exports = {
  runLocal,
  queueDepth,
  isMemoryLimitAvailable,
  isCpuQuotaAvailable,
  SANDBOX_PATH,
};
