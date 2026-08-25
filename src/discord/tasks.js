const { encodeZstd } = require("../chunks");
const { closeSession, openSession } = require("../core/sessions");
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
  const uuid = generateUUID();
  ExecuteTasks[uuid] = {
    content: encodeZstd(code),
    channelId: channelId,
    targetId: targetId,
    id: interactionId,
    token: interactionToken,
    userId: interaction.user.id,
    username: interaction.user.username,
    isCommand: isCommand,
  };
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
}

module.exports = { sendCompileRequestToRoblox };
