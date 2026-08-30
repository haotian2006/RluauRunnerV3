const { encodeZstd } = require("../chunks");
const { codeHash, getActorBlock } = require("../abuse");
const { closeSession, openSession } = require("../core/sessions");
const { selectRuntime, tryRunLocally } = require("../local/dispatch");
const { createPendingResponseEmbed } = require("./embeds");
const { createDiscordResponder } = require("./responder");
const { CompilingTasks, ExecuteTasks } = require("../state");
const { generateUUID } = require("../util");
const { cleanupScriptButtons } = require("./scriptButtons");

const TASK_TTL_MS = 1000 * 60 * 6; //How long a task can last

async function sendCompileRequestToRoblox(
  code,
  interactionId,
  interactionToken,
  channelId,
  targetId,
  interaction,
  originalInteraction,
  isCommand = false,
) {
  const baseActorKey = `discord:${interaction.user.id}`;
  const selection = await selectRuntime(code);

  await interaction.editReply({
    content: null,
    embeds: [
      createPendingResponseEmbed(selection.runtime, interaction.user.id),
    ],
    components: [],
  });

  let actorKey = `${baseActorKey}:${selection.runtime}`;
  const block = getActorBlock(actorKey);
  if (block) {
    await interaction.editReply({
      content: `Failed to start. Try again <t:${Math.ceil(block.blockedUntil / 1000)}:R>.`,
      embeds: [],
      components: [],
    });
    return;
  }

  const uuid = generateUUID();
  const timeoutId = setTimeout(() => {
    interaction.editReply({ components: [] }).catch(() => {});
    // closeSession runs the responder's cleanup, which clears the button map
    // and drops the CompilingTasks entry.
    closeSession(interaction.token);
    cleanupScriptButtons(CompilingTasks[interaction.token]?.[7]);
    delete CompilingTasks[interaction.token];
    delete ExecuteTasks[uuid];
  }, TASK_TTL_MS);
  CompilingTasks[interaction.token] = [
    interaction,
    originalInteraction,
    null,
    0,
    null,
    timeoutId,
    new Map(),
    new Map(),
  ];
  openSession(interaction.token, createDiscordResponder(interaction.token));

  if (
    await tryRunLocally(code, interaction.token, {
      allowCodegen: true,
      actorKey,
      selection,
    })
  ) {
    return;
  }

  if (!CompilingTasks[interaction.token]) return;

  if (selection.runtime === "lune") {
    actorKey = `${baseActorKey}:roblox`;
    const fallbackBlock = getActorBlock(actorKey);
    if (fallbackBlock) {
      await interaction.editReply({
        content: `Failed to start. Try again <t:${Math.ceil(fallbackBlock.blockedUntil / 1000)}:R>.`,
        embeds: [],
        components: [],
      });
      closeSession(interaction.token);
      return;
    }
    await interaction.editReply({
      content: null,
      embeds: [createPendingResponseEmbed("roblox", interaction.user.id)],
      components: [],
    });
  }

  ExecuteTasks[uuid] = {
    content: encodeZstd(code),
    channelId: channelId,
    targetId: targetId,
    id: interactionId,
    token: interactionToken,
    userId: interaction.user.id,
    username: interaction.user.username,
    actorKey,
    codeHash: codeHash(code),
    isCommand: isCommand,
  };
}

module.exports = { sendCompileRequestToRoblox };
