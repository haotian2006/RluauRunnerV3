const { logBot } = require("./log");

function describe(reason) {
  if (reason instanceof Error) {
    return `${reason.message}${reason.stack ? `\n${reason.stack}` : ""}`;
  }
  try {
    return JSON.stringify(reason);
  } catch {
    return String(reason);
  }
}

// A rejected promise nobody awaited used to kill the process: an /input echo
// over Discord's length limit took the bot down on 2026-09-14, dropping every
// interaction in flight. One user's bad input must not do that.
function installSafetyNets(onFatal = () => process.exit(1)) {
  process.on("unhandledRejection", (reason) => {
    const text = describe(reason);
    console.error("Unhandled rejection:", text);
    logBot("Unhandled Rejection", text.slice(0, 1500));
  });

  process.on("uncaughtException", (error) => {
    const text = describe(error);
    console.error("Uncaught exception:", text);
    logBot("Uncaught Exception", text.slice(0, 1500));
    // State is unknown after this, so hand over to systemd rather than limp on.
    onFatal(error);
  });
}

module.exports = { installSafetyNets, describe };
