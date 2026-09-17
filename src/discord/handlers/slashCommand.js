const axios = require("axios");

const { censorText } = require("../../filter");
const { INPUT_WINDOW_MS, checkInputRate } = require("../../abuse");
const { log, logBot } = require("../../log");
const {
  CompilingTasks,
  ExecuteTasks,
  Inputs,
} = require("../../state");
const { generateUUID, wait } = require("../../util");
const {
  cancelLocalRun,
  deliverLocalInput,
} = require("../../local/dispatch");
const { closeSession } = require("../../core/sessions");
const { getResources, resourceDisplayName } = require("../resources");
const { sendCompileRequestToRoblox } = require("../tasks");
const { cleanupScriptButtons } = require("../scriptButtons");
const { buildTagMessage } = require("../tagRender");

const INPUT_TTL_MS = 1000 * 30;
const HIDDEN_INPUT_DELETE_MS = 3000;
const STOP_SENTINEL = "STOP_ALL_SESSIONS_PLS";
const MAX_INPUT_ECHO = 1900;

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
      cancelLocalRun(token);
      clearTimeout(entry[5]);
      entry[0].editReply({ components: [] }).catch(() => {});
      cleanupScriptButtons(entry[7]);
      closeSession(token);
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

  // Never throttle a stop - it is the way out of a run that is already misbehaving.
  if (!isStop) {
    const rate = checkInputRate(`discord:${interaction.user.id}`);
    if (!rate.allowed) {
      return interaction
        .reply({
          content: `Slow down - max ${rate.limit} inputs per ${Math.round(INPUT_WINDOW_MS / 1000)}s. Try again in ${Math.ceil(rate.remainingMs / 1000)} seconds.`,
          ephemeral: true,
        })
        .catch((error) => logBot("Input Rate Reply Failed", error.message));
    }
  }

  const input = isStop
    ? STOP_SENTINEL
    : interaction.options.getString("input") || "";
  const uid = generateUUID();
  Inputs[uid] = {
    uid: uid,
    id: interaction.user.id,
    input: input,
  };
  if (!isStop) deliverLocalInput(interaction.user.id, input);

  // Unawaited on purpose, so a rejection here must be caught: an echo over
  // Discord's 2000 character limit used to crash the whole process.
  let echo = isStop ? "a stop command" : censorText(input);
  if (echo.length > MAX_INPUT_ECHO) {
    echo = `${echo.slice(0, MAX_INPUT_ECHO)}... (${input.length} characters)`;
  }
  interaction
    .reply({
      content: `sent '${echo}'`,
      ephemeral:
        interaction.commandName === "hiddeninput" ||
        interaction.commandName === "stopall",
    })
    .catch((error) => logBot("Input Reply Failed", error.message));
  if (interaction.commandName === "hiddeninput") {
    setTimeout(() => {
      interaction.deleteReply().catch(() => {});
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
  console.log(
    `User ${interaction.user.username} (${interaction.user.id}) invoked ${interaction.commandName} with code length: ${code.length} characters`,
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
  ).catch((error) =>
    logBot("Compile Dispatch Failed", error.message),
  );
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
    const { embeds, components } = buildTagMessage(text, {
      displayName: resourceDisplayName(file.name),
      url: file.html_url,
    });
    const mention = target ? `<@${target.id}> ` : "";

    await interaction.editReply({
      content: mention || undefined,
      embeds,
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
