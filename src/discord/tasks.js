const { encodeZstd } = require("../chunks");
const { codeHash, getActorBlock } = require("../abuse");
const { closeSession, openSession } = require("../core/sessions");
const { selectRuntime, tryRunLocally } = require("../local/dispatch");
const { logBot } = require("../log");
const { createPendingResponseEmbed } = require("./embeds");
const { createDiscordResponder } = require("./responder");
const { CompilingTasks, ExecuteTasks } = require("../state");
const { generateUUID } = require("../util");
const { cleanupScriptButtons } = require("./scriptButtons");

const TASK_TTL_MS = 1000 * 60 * 6; //How long a task can last

// Compiles have frozen on the pending embed with no trace at all: no stall
// watchdog, no TTL expiry, nothing. That can only happen if the flow stops
// before either timer is armed, so trace each step until they are.
function trace(token, step) {
  logBot("Compile Trace", `${String(token).slice(-8)} ${step}`);
}

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
  trace(interaction.token, "routing");
  const selection = await selectRuntime(code);

  trace(interaction.token, "editing pending embed");
  await interaction.editReply({
    content: null,
    embeds: [
      createPendingResponseEmbed(selection.runtime, interaction.user.id),
    ],
    components: [],
  });
  trace(interaction.token, "pending embed applied");

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
    // Nothing here tells the user anything, so the embed simply stops at
    // whichever pending state it reached. At minimum, say that it happened.
    logBot(
      "Task Expired",
      `${interaction.token} hit the ${TASK_TTL_MS / 1000}s TTL still unfinished ` +
        `(queued=${Boolean(ExecuteTasks[uuid])}); its embed is now stuck`,
    );
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
  trace(interaction.token, "ttl armed, entering tryRunLocally");

  const handledLocally = await tryRunLocally(code, interaction.token, {
    allowCodegen: true,
    actorKey,
    selection,
  });
  trace(interaction.token, `tryRunLocally returned ${handledLocally}`);
  if (handledLocally) {
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
