const {
  byteCodeOptionsToString,
  getByteCode,
  getByteCodeOptions,
} = require("../../tools/bytecode");
const { byteCodeModalData } = require("../modals");
const { reply } = require("../reply");
const { sendCompileRequestToRoblox } = require("../tasks");

async function handleByteCodeModal(interaction, nonce) {
  const info = byteCodeModalData[nonce];
  if (!info) return;

  const options = getByteCodeOptions();
  options.architecture =
    interaction.fields.getTextInputValue("architecture") || "";
  options.remarks = interaction.fields.getTextInputValue("remarks") === "1";
  options.optimizeLevel =
    parseInt(interaction.fields.getTextInputValue("optimize_level"), 10) || 0;
  options.debugLevel =
    parseInt(interaction.fields.getTextInputValue("debug_level"), 10) || 0;

  options.native = options.architecture !== "";

  const ephemeral = interaction.fields.getTextInputValue("ephemeral") === "1";

  // Neutralise directives in the source so the modal's options win.
  info.content = info.content
    .replace("--!optimize", "--")
    .replace("--!native", "--aaa");

  const bytecode = await getByteCode(options, info.content);
  await interaction.deferReply({ ephemeral: ephemeral });

  reply(
    interaction,
    byteCodeOptionsToString(options) + bytecode,
    ephemeral,
    "armasm",
    info.msgLink,
  );

  delete byteCodeModalData[nonce];
}

async function handleCompileModal(interaction, nonce) {
  const info = byteCodeModalData[nonce];
  if (!info) return;

  const logOutput = interaction.fields.getTextInputValue("log") === "1";
  const timestamps = interaction.fields.getTextInputValue("timestamps") === "1";
  const runTime = interaction.fields.getTextInputValue("run_time") || "15";
  const ephemeral = interaction.fields.getTextInputValue("ephemeral") === "1";
  const additionalCode =
    interaction.fields.getTextInputValue("additional_code") || "";
  await interaction.deferReply({ ephemeral: ephemeral });

  let code = info.content;
  const originalInteraction = info.data;
  const headers = `\nOUTPUT_LOGS=${
    logOutput ? "true" : "false"
  }\nTIMESTAMP=${timestamps ? "true" : "false"}\nTIMEOUT=${runTime}\n`;
  if (additionalCode.includes("{CODE}")) {
    code = additionalCode.replace(/{CODE}/g, code);
  } else {
    code = code + "\n" + additionalCode;
  }
  code = headers + "\n" + code;

  delete byteCodeModalData[nonce];
  sendCompileRequestToRoblox(
    code,
    interaction.id,
    interaction.token,
    interaction.channelId,
    interaction.targetId,
    interaction,
    originalInteraction,
  );
}

async function handleModalSubmit(interaction) {
  const [kind, nonce] = interaction.customId.split(":");
  if (kind === "bytecode_modal") {
    return handleByteCodeModal(interaction, nonce);
  } else if (kind === "compile_modal") {
    return handleCompileModal(interaction, nonce);
  }
}

module.exports = { handleModalSubmit };
