const { Client, GatewayIntentBits } = require("discord.js");
const { DISCORD_TOKEN } = require("../config");
const { logBot } = require("../log");

const client = new Client({
  intents: [GatewayIntentBits.Guilds],
});

function login() {
  client.once("ready", () => {
    console.log(`Logged in as ${client.user.tag}`);
    logBot("ready", `Logged in as ${client.user.tag}`);
  });

  client.on("error", (error) => {
    console.error(error.message);
    logBot("error", error.message);
  });

  logBot("Discord", "Logging in...\nToken Length: " + DISCORD_TOKEN?.length);
  return client
    .login(DISCORD_TOKEN)
    .then(() => {
      logBot("Discord", "Logged in successfully.");
    })
    .catch((error) => {
      logBot("Discord", "Error logging in." + error);
      console.error("Error logging in:", error);
    });
}

module.exports = { client, login };
