const {
  ActionRowBuilder,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
} = require("discord.js");
const { generateUUID, wait } = require("../util");

const byteCodeModalData = {};

const MODAL_TTL_MS = 5 * 60 * 1000;

async function createByteModal(data, code) {
  const msgLink = `https://discord.com/channels/@me/${data.channelId}/${data.targetId}`;
  const nonce = generateUUID();

  const architectureInput = new TextInputBuilder()
    .setCustomId("architecture")
    .setLabel("Target Architecture(x64, a64, a64_nf, x64_ms)")
    .setStyle(TextInputStyle.Short)
    .setValue("")
    .setRequired(false);
  const modal = new ModalBuilder()
    .setCustomId(`bytecode_modal:${nonce}`)
    .setTitle("Generate Bytecode");

  const optimizeInput = new TextInputBuilder()
    .setCustomId("optimize_level")
    .setLabel("Optimize Level (0-2)")
    .setStyle(TextInputStyle.Short)
    .setValue("2")
    .setRequired(true);

  const debugInput = new TextInputBuilder()
    .setCustomId("debug_level")
    .setLabel("Debug Level (0-2)")
    .setStyle(TextInputStyle.Short)
    .setValue("2")
    .setRequired(true);

  const remarksInput = new TextInputBuilder()
    .setCustomId("remarks")
    .setLabel("Enable Remarks? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const ephemeralInput = new TextInputBuilder()
    .setCustomId("ephemeral")
    .setLabel("Hide Text? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  modal.addComponents(
    new ActionRowBuilder().addComponents(optimizeInput),
    new ActionRowBuilder().addComponents(architectureInput),
    new ActionRowBuilder().addComponents(debugInput),
    new ActionRowBuilder().addComponents(remarksInput),
    new ActionRowBuilder().addComponents(ephemeralInput),
  );

  byteCodeModalData[nonce] = {
    data: data,
    content: code,
    msgLink: msgLink,
  };
  await data.showModal(modal);

  await wait(MODAL_TTL_MS);
  delete byteCodeModalData[nonce];
}

async function createCompileModal(data, code) {
  const msgLink = `https://discord.com/channels/@me/${data.channelId}/${data.targetId}`;
  const nonce = generateUUID();

  const modal = new ModalBuilder()
    .setCustomId(`compile_modal:${nonce}`)
    .setTitle("Generate Compile");

  const logInput = new TextInputBuilder()
    .setCustomId("log")
    .setLabel("Output Logs? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const timestamps = new TextInputBuilder()
    .setCustomId("timestamps")
    .setLabel("Include Timestamps? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const runTime = new TextInputBuilder()
    .setCustomId("run_time")
    .setLabel("Max Run Time")
    .setStyle(TextInputStyle.Short)
    .setValue("15")
    .setRequired(true);

  const ephemeralInput = new TextInputBuilder()
    .setCustomId("ephemeral")
    .setLabel("Hide Result? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const additionalCode = new TextInputBuilder()
    .setCustomId("additional_code")
    .setLabel("Additional Code (Optional)")
    .setStyle(TextInputStyle.Paragraph)
    .setValue(
      `--native\n--optimize 2\nlocal function run()\n\t{CODE}\nend\nlocal results = run()`,
    )
    .setRequired(false);

  modal.addComponents(
    new ActionRowBuilder().addComponents(additionalCode),
    new ActionRowBuilder().addComponents(logInput),
    new ActionRowBuilder().addComponents(timestamps),
    new ActionRowBuilder().addComponents(runTime),
    new ActionRowBuilder().addComponents(ephemeralInput),
  );

  byteCodeModalData[nonce] = {
    data: data,
    content: code,
    msgLink: msgLink,
  };

  setTimeout(() => {
    delete byteCodeModalData[nonce];
  }, MODAL_TTL_MS);
  await data.showModal(modal);
}

module.exports = { byteCodeModalData, createByteModal, createCompileModal };
