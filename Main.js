const {
  CALLBACK_URL,
  ENABLE_DISCORD,
  ENABLE_WEB,
  missingTools,
} = require("./src/config");
const { logBot } = require("./src/log");
const { migrationHint, reportProfiles } = require("./src/profiles");
const { state } = require("./src/state");
const { start: startHttpServer } = require("./src/http/server");
const { checkRobloxServer } = require("./src/roblox/session");
const { login } = require("./src/discord/client");
const { registerInteractionHandler } = require("./src/discord/handlers");

function main() {
  const { loaded, skipped } = reportProfiles();
  if (loaded.length === 0) {
    if (skipped.length) {
      console.error(
        "Every profile failed to load; fix the errors above and restart.",
      );
    } else {
      console.error(migrationHint());
    }
    process.exit(1);
  }

  const frontEnds = [
    ENABLE_DISCORD && "discord",
    ENABLE_WEB && "web",
  ].filter(Boolean);
  console.log(`Front ends: ${frontEnds.join(", ")}`);
  logBot("Main", `Front ends: ${frontEnds.join(", ")}`);

  const missing = missingTools();
  if (missing.length) {
    console.warn(
      `Warning: missing tool binaries: ${missing.join(", ")}.
` +
        "Run `npm run fetch-tools`. /compile still works; bytecode, analyze, " +
        "ast and format will fail until they are installed.",
    );
  }

  state.CallbackUrl = CALLBACK_URL;

  startHttpServer();

  logBot("Check Roblox Server", "Checking if Roblox server is online...");
  checkRobloxServer();

  logBot("Main", "Starting main bot process...");

  if (ENABLE_DISCORD) {
    console.log("Bot is starting...");
    logBot("Discord", "Registering interaction handler...");
    registerInteractionHandler();
    login();
  }
}

main();
