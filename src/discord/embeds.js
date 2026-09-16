const { EmbedBuilder } = require("discord.js");
const { censorText } = require("../filter");
const { logBot } = require("../log");
const { retryDiscordOperation } = require("./reply");

const ANSI_GREY = "\u001b[0;30m";
const ANSI_RESET = "\u001b[0m";

function filesFromMap(fileMap) {
  return fileMap?.size > 0
    ? [...fileMap.values()].map(([l, ft, fn]) => ({
        name: `${fn}.${ft}`,
        attachment: l,
      }))
    : undefined;
}

function liveAttachmentOptions(existingAttachments, fileMap, changedFile) {
  if (!changedFile) return {};
  return {
    attachments: [...existingAttachments]
      .filter(
        (attachment) =>
          attachment.name !== changedFile.name && fileMap?.has(attachment.name),
      )
      .map((attachment) => ({ id: attachment.id })),
    files: [changedFile],
  };
}

// An empty ansi block renders as a bare "1" gutter, which reads as a result
// that never arrived rather than one with no output. Keep the block and
// put dimmed placeholder text in it so every state looks the same.
function describeBody(responseContent, isLast) {
  // Only a total absence of output is "no output": a script that printed a
  // space or a blank line did produce something.
  const censored = censorText(String(responseContent ?? ""));
  const body = censored.length
    ? censored
    : `${ANSI_GREY}${isLast ? "No output" : "Running..."}${ANSI_RESET}`;
  return `\`\`\`ansi\n${body}\n\`\`\``;
}

function createResponseEmbed(
  serverNum,
  userId,
  responseContent,
  isLast,
  runtime,
  msgLink,
  sourceUrl,
) {
  const runtimeLabel =
    serverNum == null
      ? null
      : serverNum === "Lune"
        ? "Lune"
        : `Server #${serverNum}`;
  const embed = new EmbedBuilder()
    .setTitle(
      runtimeLabel
        ? `Luau Compiler Results | ${runtimeLabel}`
        : "Luau Compiler Results",
    )
    .setDescription(
      `Requested by: <@${userId}>${sourceUrl ? ` | [see raw](${sourceUrl})` : ""}` +
        describeBody(responseContent, isLast),
    )
    .setColor(0x8ce4ff);

  if (isLast) {
    embed.setFooter({ text: `Compilation completed | ${runtime}s` });
    embed.setColor(3447003);
  }

  if (msgLink) {
    embed.setURL(msgLink);
  }

  return embed;
}

function createPendingResponseEmbed(runtime, userId, sourceUrl) {
  const embed = createResponseEmbed(
    runtime === "lune" ? "Lune" : null,
    userId,
    "",
    false,
    0,
    null,
    sourceUrl,
  );
  if (runtime === "roblox") embed.setTitle("Starting Server...");
  return embed;
}

async function handleFollowUpResponse(
  interaction,
  embed,
  sentUrl,
  fileMap,
  dmMessage,
  changedFile,
) {
  const followUpEmbed = new EmbedBuilder(embed.data)
    .setTitle("Follow up request")
    .setURL(sentUrl);

  const files = filesFromMap(fileMap);

  if (interaction.guild) {
    await retryDiscordOperation(
      () =>
        interaction.followUp({
          ephemeral: true,
          embeds: [followUpEmbed],
          ...(files && { files }),
        }),
      3,
      "Follow-up in guild",
    );
  } else {
    try {
      followUpEmbed.addFields(
        {
          name: "Info",
          value:
            "This is a follow up request. You can still use `/input` to send inputs to the bot. The purpose of this is allow you to send inputs without having to scroll up to find the changes. This will also update the main interaction message.",
          inline: false,
        },
        {
          name: "Tip",
          value: "Use `/hiddeninput` to not flood dms with inputs",
          inline: true,
        },
      );

      if (dmMessage) {
        const editOptions = {
          embeds: [followUpEmbed],
          ...liveAttachmentOptions(
            dmMessage.attachments.values(),
            fileMap,
            changedFile,
          ),
        };

        return await retryDiscordOperation(
          () => dmMessage.edit(editOptions),
          3,
          "Edit DM message",
        );
      } else {
        const newDmMessage = await retryDiscordOperation(
          () =>
            interaction.user.send({
              embeds: [followUpEmbed],
              ...(files && { files }),
            }),
          3,
          "Send DM",
        );

        await interaction.followUp({
          content:
            "A new DM has been sent to you with the follow up response. " +
            newDmMessage.url,
          ephemeral: true,
        });

        return newDmMessage;
      }
    } catch (err) {
      logBot("Follow-up Error", `Failed to send DM follow-up: ${err.message}`);
    }
  }
  return null;
}

module.exports = {
  filesFromMap,
  liveAttachmentOptions,
  createPendingResponseEmbed,
  createResponseEmbed,
  handleFollowUpResponse,
};
