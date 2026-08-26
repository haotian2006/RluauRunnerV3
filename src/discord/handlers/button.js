const {
  CompilingTasks,
  Inputs,
  ScriptButtonCallbacks,
  docCodeStore,
} = require("../../state");
const { generateUUID } = require("../../util");
const { SCRIPT_BUTTON_PREFIX } = require("../scriptButtons");
const { sendCompileRequestToRoblox } = require("../tasks");

const TAG_RUN_PREFIX = "tag_run:";
const INPUT_TTL_MS = 30 * 1000;

function isScriptButton(interaction) {
  return (
    interaction.isButton() &&
    interaction.customId.startsWith(SCRIPT_BUTTON_PREFIX)
  );
}

async function handleScriptButton(interaction) {
  const buttonId = interaction.customId.slice(SCRIPT_BUTTON_PREFIX.length);
  const callback = ScriptButtonCallbacks.get(buttonId);
  const definition = CompilingTasks[callback?.token]?.[7]?.get(buttonId);

  if (!callback || !definition) {
    ScriptButtonCallbacks.delete(buttonId);
    await interaction.reply({
      content: "This button has expired.",
      ephemeral: true,
    });
    return;
  }
  if (callback.ownerOnly && interaction.user.id !== callback.ownerUserId) {
    await interaction.reply({
      content: "Only the user who started this script can use this button.",
      ephemeral: true,
    });
    return;
  }

  await interaction.deferUpdate();
  const uid = generateUUID();
  Inputs[uid] = {
    uid,
    id: callback.ownerUserId,
    input: "",
    buttonId,
    targetProcessId: callback.processId,
    clickUserId: interaction.user.id,
    clickUsername: interaction.user.username,
  };
  setTimeout(() => delete Inputs[uid], INPUT_TTL_MS);
}

function isTagRun(interaction) {
  return (
    interaction.isButton() && interaction.customId.startsWith(TAG_RUN_PREFIX)
  );
}

async function handleTagRun(interaction) {
  const uuid = interaction.customId.slice(TAG_RUN_PREFIX.length);
  const code = docCodeStore[uuid];
  if (!code) {
    await interaction.reply({
      content: "This button has expired.",
      ephemeral: true,
    });
    return;
  }
  await interaction.deferReply({ ephemeral: false });
  sendCompileRequestToRoblox(
    code,
    interaction.id,
    interaction.token,
    interaction.channelId,
    null,
    interaction,
    null,
    false,
  );
}

module.exports = {
  isScriptButton,
  handleScriptButton,
  isTagRun,
  handleTagRun,
};
