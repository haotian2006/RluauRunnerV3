const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID } = require("crypto");
const { spawn } = require("child_process");

const {
  LOCAL_MAX_CONCURRENT,
  LOCAL_MAX_LINES,
  LOCAL_MAX_LINE_BYTES,
  LOCAL_MEMORY_LIMIT_MB,
  LOCAL_CPU_QUOTA_PERCENT,
  LOCAL_ISOLATION,
  LOCAL_LUNE_STAGED_PATH,
  LOCAL_SANDBOX_USER,
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
// After SIGKILL, how long to wait for 'close' before giving up on it entirely.
const HARD_SETTLE_GRACE_MS = 5000;
// After the process exits, how long to let the stdio pipes drain before
// settling without them.
const EXIT_DRAIN_MS = 1500;

// Capped, not unbounded: this box shares few cores with the Discord client.
let active = 0;
const waiting = [];

function acquireSlot(signal, queueIfBusy) {
  if (signal?.aborted) return Promise.resolve(false);
  if (active < LOCAL_MAX_CONCURRENT) {
    active += 1;
    return Promise.resolve(true);
  }
  if (!queueIfBusy) return Promise.resolve("busy");
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

function buildChildEnv(tmpDir) {
  const env =
    process.platform === "win32"
      ? {
          SystemRoot: process.env.SystemRoot,
          windir: process.env.windir,
          TEMP: tmpDir,
          TMP: tmpDir,
          PATH: process.env.SystemRoot
            ? `${process.env.SystemRoot}\\System32`
            : process.env.PATH,
        }
      : {
          PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          HOME: tmpDir,
          TMPDIR: tmpDir,
          LANG: process.env.LANG || "C.UTF-8",
          DBUS_SYSTEM_BUS_ADDRESS: process.env.DBUS_SYSTEM_BUS_ADDRESS,
          XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
        };

  for (const key of Object.keys(env)) {
    if (env[key] === undefined) delete env[key];
  }
  return env;
}
// A --scope is only a cgroup: same uid, same filesystem, same /home as the
// bot, so it caps resources and nothing else. A transient service has an exec
// context and can also take the filesystem and privilege restrictions below.
//
// Nothing here may reach into /home: ProtectHome=yes makes it inaccessible,
// and a BindReadOnlyPaths for a file underneath does NOT punch back through
// (verified on the box - the unit dies with 203/EXEC). Hence the staged binary
// and the per-job copy of sandbox.luau that the caller drops in tmpDir.
function buildServiceArgs(jobPath, tmpDir, sandboxPath, timeoutMs) {
  const properties = [
    // Transient units default to root. Without this the sandbox would run with
    // MORE privilege than scope mode, and an empty CapabilityBoundingSet then
    // costs root CAP_DAC_OVERRIDE, so it cannot even enter its own 0700 tmpdir.
    `User=${LOCAL_SANDBOX_USER}`,
    `WorkingDirectory=${tmpDir}`,
    `ReadWritePaths=${tmpDir}`,
    "ProtectHome=yes",
    "ProtectSystem=strict",
    "ProtectProc=invisible",
    "PrivateDevices=yes",
    "PrivateNetwork=yes",
    "NoNewPrivileges=yes",
    "RestrictSUIDSGID=yes",
    "RestrictRealtime=yes",
    "RestrictNamespaces=yes",
    "LockPersonality=yes",
    "ProtectKernelTunables=yes",
    "ProtectKernelModules=yes",
    "ProtectControlGroups=yes",
    "CapabilityBoundingSet=",
    "AmbientCapabilities=",
    "SystemCallFilter=@system-service",
    "SystemCallFilter=~@privileged @resources @obsolete",
    `RuntimeMaxSec=${Math.ceil(timeoutMs / 1000) + 10}`,
  ];

  if (LOCAL_MEMORY_LIMIT_MB) {
    properties.push(`MemoryMax=${LOCAL_MEMORY_LIMIT_MB}M`, "MemorySwapMax=0");
  }
  if (LOCAL_CPU_QUOTA_PERCENT) {
    properties.push(`CPUQuota=${LOCAL_CPU_QUOTA_PERCENT}%`);
  }

  const args = ["--pipe", "--wait", "--quiet", "--collect"];
  for (const property of properties) args.push("-p", property);
  args.push("--", LOCAL_LUNE_STAGED_PATH, "run", sandboxPath, jobPath);
  return args;
}

// No portable memory cap in Node. ulimit is a shell builtin, hence bash -c;
// Windows has no equivalent short of Job Objects.
function buildCommand(jobPath, tmpDir, sandboxPath, timeoutMs) {
  const args = ["run", SANDBOX_PATH, jobPath];

  let command = PATH_TO_LUNE;
  let finalArgs = args;

  if (process.platform === "win32" || LOCAL_ISOLATION === "none") {
    return { command, args: finalArgs, shell: false };
  }

  if (LOCAL_ISOLATION === "service") {
    return {
      command: "systemd-run",
      args: buildServiceArgs(jobPath, tmpDir, sandboxPath, timeoutMs),
      shell: false,
    };
  }

  if (LOCAL_MEMORY_LIMIT_MB) {
    const quoted = [PATH_TO_LUNE, ...args]
      .map((part) => `'${String(part).replace(/'/g, "'\\''")}'`)
      .join(" ");
    command = "/bin/bash";
    finalArgs = [
      "-c",
      `ulimit -v ${LOCAL_MEMORY_LIMIT_MB * 1024}; exec ${quoted}`,
    ];
  }

  if (LOCAL_CPU_QUOTA_PERCENT) {
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

function cleanupJob(tmpDir, jobPath) {
  try {
    if (jobPath) fs.unlinkSync(jobPath);
  } catch {}
  try {
    if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
  } catch {}
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
    isWeb = false,
    queueIfBusy = true,
    signal = null,
  } = options;

  const hot = parseHotComments(source);

  const acquired = await acquireSlot(signal, queueIfBusy);
  if (acquired === "busy") {
    return {
      ok: false,
      timedOut: false,
      luneBusy: true,
      error: "All Lune execution slots are busy",
    };
  }
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
  // Declared out here on purpose: cleanup() below lives in the promise
  // executor's scope and cannot see consts block-scoped to this try.
  let tmpDir = null;
  let jobPath = null;
  try {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-local-"));
    jobPath = path.join(tmpDir, "job.json");

    fs.writeFileSync(
      jobPath,
      JSON.stringify({
        source,
        optimizationLevel: hot.optimizationLevel,

        codegenEnabled: allowCodegen && hot.native,
        maxLines: LOCAL_MAX_LINES,
        maxLineBytes: LOCAL_MAX_LINE_BYTES,
        isWeb,
        processId: randomUUID(),
      }),
      "utf8",
    );

    // Service mode cannot read the repo copy: ProtectHome=yes hides /home from
    // the unit. Copying per job (rather than staging it next to the binary)
    // keeps it impossible for the sandbox to go stale against the repo.
    let sandboxPath = SANDBOX_PATH;
    if (LOCAL_ISOLATION === "service") {
      sandboxPath = path.join(tmpDir, "sandbox.luau");
      fs.copyFileSync(SANDBOX_PATH, sandboxPath);
    }

    ({ command, args } = buildCommand(jobPath, tmpDir, sandboxPath, timeoutMs));
  } catch (error) {
    cleanupJob(tmpDir, jobPath);
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
      child = spawn(command, args, {
        stdio: ["pipe", "pipe", "pipe"],

        cwd: tmpDir,
        env: buildChildEnv(tmpDir),
      });
      child.stdin.on("error", () => {});
      try {
        const sendMessage = (payload) => {
          if (!child.stdin.writable || child.stdin.destroyed) return false;
          child.stdin.write(`${JSON.stringify(payload)}\n`, () => {});
          return true;
        };
        onInputReady(
          (value) =>
            sendMessage(
              Buffer.isBuffer(value)
                ? { kind: "buffer", hex: value.toString("hex") }
                : { kind: "string", value: String(value ?? "") },
            ),
          sendMessage,
        );
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
    let hardSettleTimer = null;
    let heartbeatTimer = null;
    let lastHeartbeatAt = 0;
    let timeoutKind = null;

    let scriptErrored = false;
    let abandoned = false;

    function terminate(reason, kind = null) {
      if (settled || timedOut || cancelled) return;
      timedOut = reason === "timeout";
      timeoutKind = timedOut ? kind : null;
      cancelled = reason === "cancelled";
      child.kill("SIGTERM");

      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);

      // 'close' only fires once the process has exited AND every stdio pipe
      // has hit EOF. A grandchild that inherited stdout can hold that pipe
      // open after the direct child is gone, and then 'close' never arrives
      // and this promise hangs forever, leaking its execution slot. Settle on
      // our own clock instead of trusting the event.
      hardSettleTimer = setTimeout(() => {
        if (settled) return;
        abandoned = true;
        finish(null);
      }, KILL_GRACE_MS + HARD_SETTLE_GRACE_MS);
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
      cleanupJob(tmpDir, jobPath);
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
      if (hardSettleTimer) clearTimeout(hardSettleTimer);
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

    function finish(code) {
      if (settled) return;
      if (stdoutBuffer.trim()) handleLine(stdoutBuffer);

      if (timedOut) {
        settle({
          ok: false,
          timedOut: true,
          timeoutKind,
          abandoned,
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
          abandoned,
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
        abandoned,
        error:
          code === 0
            ? null
            : stripHostPaths(stderr.trim()) || `Sandbox exited with ${code}`,
      });
    }

    child.on("close", finish);

    // 'close' additionally waits for every copy of the stdio pipes to be
    // closed, which a surviving grandchild can stall indefinitely. The exit
    // code is already final here, so drain briefly and then settle regardless.
    child.on("exit", (code) => {
      if (settled) return;
      const drain = setTimeout(() => {
        if (settled) return;
        abandoned = true;
        finish(code);
      }, EXIT_DRAIN_MS);
      drain.unref?.();
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
