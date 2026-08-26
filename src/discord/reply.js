const { logBot } = require("../log");
const { wait } = require("../util");

function getLinkFromData(data) {
  const channel_id = data.channelId;
  const msgID = data.targetId;
  return msgID ? `https://discord.com/channels/@me/${channel_id}/${msgID}` : "";
}

async function retryDiscordOperation(
  operation,
  maxRetries = 3,
  operationName = "Discord operation",
) {
  let lastError;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      logBot(
        "Discord Retry",
        `${operationName} failed (attempt ${attempt}/${maxRetries}): ${error.message}`,
      );

      if (attempt < maxRetries) {
        const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
        await wait(delay);
      }
    }
  }
  throw lastError;
}

async function reply(
  interaction,
  content,
  ephemeral = false,
  fileType = "lua",
  msgLink = null,
) {
  try {
    const len = content.length;
    const link = msgLink || getLinkFromData(interaction);
    if (len > 1300) {
      await interaction.editReply({
        content:
          "Results For " + link + ":\nOutput too long sending as a file...",
        files: [
          {
            name: "output." + fileType,
            attachment: Buffer.from(content, "utf-8"),
          },
        ],
        ephemeral: ephemeral,
      });
    } else {
      await interaction.editReply({
        content:
          "Results For " +
          link +
          ":\n```" +
          `${fileType}\n` +
          content +
          "\n```",
        ephemeral: ephemeral,
      });
    }
  } catch (error) {
    console.error("Error in reply function:", error);
  }
}

module.exports = { getLinkFromData, retryDiscordOperation, reply };
