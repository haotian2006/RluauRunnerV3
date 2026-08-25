const { CALLBACK_URL } = require("./src/config");
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

  state.CallbackUrl = CALLBACK_URL;

  startHttpServer();

  logBot("Check Roblox Server", "Checking if Roblox server is online...");
  checkRobloxServer();

  console.log("Bot is starting...");
  logBot("Main", "Starting main bot process...");
  logBot("Discord", "Registering interaction handler...");
  registerInteractionHandler();
  login();
}

main();
