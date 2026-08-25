const axios = require("axios");
const {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  EmbedBuilder,
} = require("discord.js");

const {
  censorText,
  extractDocCodeBlocks,
  stripNoShowForDisplay,
} = require("../../filter");
const { log } = require("../../log");
const {
  CompilingTasks,
  ExecuteTasks,
  Inputs,
  docCodeStore,
} = require("../../state");
const { generateUUID, wait } = require("../../util");
const { getResources, resourceDisplayName } = require("../resources");
const { sendCompileRequestToRoblox } = require("../tasks");
const { cleanupScriptButtons } = require("../scriptButtons");

const INPUT_TTL_MS = 1000 * 30;
const DOC_CODE_TTL_MS = 1000 * 60 * 10;
const HIDDEN_INPUT_DELETE_MS = 3000;
const STOP_SENTINEL = "STOP_ALL_SESSIONS_PLS";
const MAX_EMBED_DESCRIPTION = 4096;

async function handlePing(interaction) {
  const sent = await interaction.reply({
    content: "Pinging...",
    fetchReply: true,
  });
  const diff = sent.createdTimestamp - interaction.createdTimestamp;
  log(
    interaction.user.id,
    interaction.user.username,
    interaction.commandName,
    `Pong! ${diff}ms.`,
  );
  await interaction.editReply(`Pong! ${diff}ms.`);
}

function stopUserSessions(interaction) {
  const userId = interaction.user.id;
  let removed = 0;
  for (const token in CompilingTasks) {
    const entry = CompilingTasks[token];
    if (!entry || !entry[0] || !entry[0].user) continue;
    if (entry[0].user.id === userId) {
      clearTimeout(entry[5]);
      entry[0].editReply({ components: [] }).catch(() => {});
      cleanupScriptButtons(entry[7]);
      delete CompilingTasks[token];
      removed++;
      for (const taskId in ExecuteTasks) {
        if (ExecuteTasks[taskId] && ExecuteTasks[taskId].token === token) {
          delete ExecuteTasks[taskId];
        }
      }
    }
  }
  return removed;
}

async function handleInputCommand(interaction) {
  const isStop = interaction.commandName === "stopall";
  const input = isStop
    ? STOP_SENTINEL
    : interaction.options.getString("input") || "";
  const uid = generateUUID();
  Inputs[uid] = {
    uid: uid,
    id: interaction.user.id,
    input: input,
  };

  interaction.reply({
    content: `sent '${isStop ? "a stop command" : censorText(input)}'`,
    ephemeral:
      interaction.commandName === "hiddeninput" ||
      interaction.commandName === "stopall",
  });
  if (interaction.commandName === "hiddeninput") {
    setTimeout(() => {
      interaction.deleteReply();
    }, HIDDEN_INPUT_DELETE_MS);
  }

  log(
    interaction.user.id,
    interaction.user.username,
    interaction.commandName,
    `Input Length: ${input.length} characters`,
  );

  if (isStop) {
    try {
      const removed = stopUserSessions(interaction);
      log(
        interaction.user.id,
        interaction.user.username,
        interaction.commandName,
        `Stopped ${removed} session(s)`,
      );
    } catch (err) {
      console.error("Error stopping sessions:", err);
    }
  }
  wait(INPUT_TTL_MS).then(() => {
    delete Inputs[uid];
  });
}

async function handleCompileCommand(interaction) {
  await interaction.deferReply({ ephemeral: false });
  const code = interaction.options.getString("code");
  log(
    interaction.user.id,
    interaction.user.username,
    interaction.commandName,
    `Code length: ${code.length} characters`,
  );

  sendCompileRequestToRoblox(
    code,
    interaction.id,
    interaction.token,
    interaction.channelId,
    interaction.targetId,
    interaction,
    null,
    true,
  );
}

function buildTagComponents(codeBlocks) {
  const components = [];
  if (codeBlocks.length === 0) return components;

  const uuids = codeBlocks.map((block) => {
    const uuid = generateUUID();
    docCodeStore[uuid] =
      `log("Running: ${block.label}", "cyan", true)\n${block.code}`;
    setTimeout(() => {
      delete docCodeStore[uuid];
    }, DOC_CODE_TTL_MS);
    return uuid;
  });

  for (let i = 0; i < Math.min(codeBlocks.length, 25); i += 5) {
    const row = new ActionRowBuilder();
    const slice = codeBlocks.slice(i, i + 5);
    row.addComponents(
      slice.map((block, j) =>
        new ButtonBuilder()
          .setCustomId(`tag_run:${uuids[i + j]}`)
          .setLabel(block.label)
          .setStyle(ButtonStyle.Primary),
      ),
    );
    components.push(row);
  }
  return components;
}

async function handleTagCommand(interaction) {
  await interaction.deferReply({ ephemeral: false });
  const resourceName = interaction.options.getString("resource");
  const target = interaction.options.getUser("target");
  log(
    interaction.user.id,
    interaction.user.username,
    interaction.commandName,
    `Tag: ${resourceName}`,
  );
  try {
    const files = await getResources();
    const file = files.find((f) => f.name === resourceName);
    if (!file) {
      await interaction.editReply({
        content: `Resource \`${resourceName}\` not found.`,
      });
      return;
    }
    const contentRes = await axios.get(file.download_url);
    const text = contentRes.data;
    const displayName = resourceDisplayName(file.name);
    const displayText = stripNoShowForDisplay(text);
    const embed = new EmbedBuilder()
      .setTitle(displayName)
      .setDescription(
        displayText.length > MAX_EMBED_DESCRIPTION
          ? displayText.substring(0, MAX_EMBED_DESCRIPTION - 3) + "..."
          : displayText,
      )
      .setURL(file.html_url)
      .setColor(0x5865f2);
    const mention = target ? `<@${target.id}> ` : "";

    const components = buildTagComponents(extractDocCodeBlocks(text));

    await interaction.editReply({
      content: mention || undefined,
      embeds: [embed],
      components,
      allowedMentions: { users: target ? [target.id] : [] },
    });
  } catch (e) {
    await interaction.editReply({
      content: `Failed to fetch resource: ${e.message}`,
    });
  }
}

async function handleSlashCommand(interaction) {
  if (interaction.commandName === "ping") {
    return handlePing(interaction);
  } else if (interaction.commandName === "help") {
    return interaction.reply({
      content: `Check out the documentation at https://haotian2006.github.io/LuauBotSite/`,
    });
  } else if (
    interaction.commandName === "input" ||
    interaction.commandName === "hiddeninput" ||
    interaction.commandName === "stopall"
  ) {
    return handleInputCommand(interaction);
  } else if (interaction.commandName === "compile") {
    return handleCompileCommand(interaction);
  } else if (interaction.commandName === "tag") {
    return handleTagCommand(interaction);
  }
}

module.exports = { handleSlashCommand };
