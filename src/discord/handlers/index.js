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

async function reportInteractionError(interaction, error) {
  try {
    if (typeof interaction.isAutocomplete === "function" && interaction.isAutocomplete()) {
      return;
    }
    const content = `Something went wrong: ${error.message}`;
    if (interaction.deferred || interaction.replied) {
      await interaction.editReply({ content, embeds: [], components: [] });
    } else {
      await interaction.reply({ content, ephemeral: true });
    }
  } catch (replyError) {
    logBot(
      "Interaction Error",
      `Could not report the failure to the user: ${replyError.message}`,
    );
  }
}

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
      // Without this a handler that throws after deferReply leaves the user on
      // "thinking..." forever, with the reason only in the server log.
      await reportInteractionError(interaction, error);
    }
  });
}

module.exports = { registerInteractionHandler };
