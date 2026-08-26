const { EmbedBuilder } = require("discord.js");

const { safeMessage } = require("../sanitize");
const { logBot } = require("../log");
const { CompilingTasks } = require("../state");
const {
  createResponseEmbed,
  handleFollowUpResponse,
  liveAttachmentOptions,
} = require("./embeds");
const { getLinkFromData, retryDiscordOperation } = require("./reply");
const { cleanupScriptButtons } = require("./scriptButtons");

function createDiscordResponder(token) {
  function entry() {
    return CompilingTasks[token];
  }

  return {
    // Matches the Roblox executor's visible line count. SSE has no limit.
    outputLineLimit: 24,

    link() {
      const current = entry();
      if (!current) return null;
      const [interaction, originalInteraction] = current;
      return getLinkFromData(originalInteraction || interaction);
    },

    async deliver({
      responseContent,
      logs,
      changedFileName,
      fileMap,
      isLast,
      runtime,
      serverNum,
      followUp,
    }) {
      const current = entry();
      if (!current) return;

      const [
        interaction,
        originalInteraction,
        ,
        ,
        dmMessage = null,
        ,
        attachmentMap = new Map(),
      ] = current;

      const link = getLinkFromData(originalInteraction || interaction);

      const embed = createResponseEmbed(
        serverNum,
        interaction.user.id,
        responseContent,
        isLast,
        runtime,
        link,
      );

      const replyOptions = {
        content: null,
        embeds: [embed],
        ...(isLast && { components: [] }),
      };

      if (changedFileName) {
        Object.assign(
          replyOptions,
          liveAttachmentOptions(attachmentMap.values(), fileMap, {
            name: changedFileName,
            attachment: logs,
          }),
        );
      }

      const sent = await retryDiscordOperation(
        () => interaction.editReply(replyOptions),
        3,
        "Edit reply",
      );

      if (changedFileName && CompilingTasks[token]) {
        CompilingTasks[token][6] = new Map(
          [...sent.attachments.values()].map((attachment) => [
            attachment.name,
            attachment,
          ]),
        );
      }

      if (followUp || dmMessage) {
        const newDmMessage = await handleFollowUpResponse(
          interaction,
          embed,
          sent.url,
          fileMap,
          dmMessage,
          changedFileName
            ? { name: changedFileName, attachment: logs }
            : undefined,
        );

        if (newDmMessage && CompilingTasks[token]) {
          CompilingTasks[token][4] = newDmMessage;
        }
      }
    },

    async fail(error, link) {
      const current = entry();
      if (!current) return;
      const [interaction] = current;

      try {
        let errorEmbed;
        try {
          const existing = (await interaction.fetchReply())?.embeds?.[0];
          errorEmbed = existing ? new EmbedBuilder(existing.data) : null;
        } catch {}

        if (!errorEmbed) {
          errorEmbed = new EmbedBuilder().setDescription(
            `Requested by: <@${interaction.user.id}>`,
          );
        }

        errorEmbed
          .setFooter({ text: `ERROR: ${safeMessage(error)}` })
          .setColor(0xff0000);

        if (link) {
          errorEmbed.setURL(link);
        }

        await retryDiscordOperation(
          () =>
            interaction.editReply({
              content: null,
              embeds: [errorEmbed],
              components: [],
            }),
          2,
          "Error reply",
        );
      } catch (editError) {
        logBot(
          "Error Reply Failed",
          `Failed to edit reply with error: ${editError.message}`,
        );
      }
    },

    close() {
      const current = entry();
      if (!current) return;
      clearTimeout(current[5]);
      cleanupScriptButtons(current[7]);
      delete CompilingTasks[token];
    },
  };
}

module.exports = { createDiscordResponder };
