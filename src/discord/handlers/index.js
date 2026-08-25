const { logBot } = require("../../log");
const { client } = require("../client");
const { wrapEphemeral } = require("../permissions");
const { handleAutocomplete } = require("./autocomplete");
const {
  handleScriptButton,
  handleTagRun,
  isScriptButton,
  isTagRun,
} = require("./button");
const { handleContextMenu } = require("./contextMenu");
const { handleModalSubmit } = require("./modalSubmit");
const { handleSlashCommand } = require("./slashCommand");

function registerInteractionHandler() {
  client.on("interactionCreate", async (interaction) => {
    try {
      wrapEphemeral(interaction);

      if (isScriptButton(interaction)) {
        return await handleScriptButton(interaction);
      }

      if (isTagRun(interaction)) {
        return await handleTagRun(interaction);
      }

      if (interaction.isAutocomplete()) {
        return await handleAutocomplete(interaction);
      }

      if (interaction.isMessageContextMenuCommand()) {
        return await handleContextMenu(interaction);
      }

      if (interaction.isModalSubmit()) {
        return await handleModalSubmit(interaction);
      }

      if (interaction.isCommand()) {
        return await handleSlashCommand(interaction);
      }
    } catch (error) {
      console.error("Error handling interaction:", error);
      logBot(
        "Interaction Error",
        `Error handling interaction: ${error.message}`,
      );
    }
  });
}

module.exports = { registerInteractionHandler };
