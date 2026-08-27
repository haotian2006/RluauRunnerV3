const { MAX_DATA_TO_SEND } = require("../../config");
const { encodeZstd } = require("../../chunks");
const { log, logBot } = require("../../log");
const { deliverLocalInput } = require("../../local/dispatch");
const { Inputs } = require("../../state");
const { generateUUID } = require("../../util");
const { analyzeLuau, formatLuau, generateAST } = require("../../tools/luau");
const {
  byteCodeOptionsToString,
  getAnalysisOptions,
  getByteCode,
  getByteCodeOptions,
} = require("../../tools/bytecode");
const {
  getCodeFromContextMenu,
  getInputsFromContext,
} = require("../attachments");
const { createByteModal, createCompileModal } = require("../modals");
const { reply } = require("../reply");
const { sendCompileRequestToRoblox } = require("../tasks");

const INPUT_TTL_MS = 1000 * 30;

async function handleInputContext(interaction) {
  await interaction.deferReply();
  const { inputs, failures } = await getInputsFromContext(interaction);
  for (const input of inputs) {
    try {
      const eSize = encodeZstd(input).length;

      if (eSize > MAX_DATA_TO_SEND) {
        await interaction.editReply({
          content: `Input exceeds maximum size of ${Math.floor(
            MAX_DATA_TO_SEND / 1024,
          )} KB after compression (current size: ${Math.floor(
            eSize / 1024,
          )} KB).`,
        });

        return;
      }

      const uid = generateUUID();
      Inputs[uid] = {
        uid: uid,
        id: interaction.user.id,
        input: input,
      };
      deliverLocalInput(interaction.user.id, input);

      log(
        interaction.user.id,
        interaction.user.username,
        interaction.commandName,
        `Input Length: ${input.length} characters`,
      );
      setTimeout(() => {
        delete Inputs[uid];
      }, INPUT_TTL_MS);
    } catch (err) {
      logBot("Input Error", `Error processing input: ${err.message}`);
    }
  }
  const sent = "Sent " + inputs.length + " Input(s)";
  await interaction.editReply({
    content: failures.length
      ? `${sent}\nSkipped ${failures.length}: ${failures.join("; ")}`
      : sent,
  });
}

/**
 * Message context-menu commands
 *
 * @param {import('discord.js').MessageContextMenuCommandInteraction} interaction
 */
async function handleContextMenu(interaction) {
  if (interaction.commandName === "input") {
    return handleInputContext(interaction);
  }

  const code = await getCodeFromContextMenu(interaction);

  log(
    interaction.user.id,
    interaction.user.username,
    interaction.commandName,
    `Code length: ${code.length} characters`,
  );
  console.log(
    `User ${interaction.user.username} (${interaction.user.id}) invoked ${interaction.commandName} with code length: ${code.length} characters`,
  );

  if (interaction.commandName === "bytecode") {
    await interaction.deferReply({ ephemeral: false });
    console.log("Generating bytecode with options...");
    const options = getByteCodeOptions(code);
    const bytecode =
      byteCodeOptionsToString(options) + (await getByteCode(options, code));
    await reply(interaction, bytecode, false, "armasm");
  } else if (interaction.commandName === "analyze") {
    await interaction.deferReply({ ephemeral: false });
    const options = getAnalysisOptions(code);

    const analysis = await analyzeLuau(
      code.replace("--!annotate", ""),
      options,
    );
    await reply(interaction, analysis.output, false, "lua");
  } else if (interaction.commandName === "ast") {
    await interaction.deferReply({ ephemeral: false });
    const ast = await generateAST(code);
    await reply(interaction, ast.output, false, "json");
  } else if (interaction.commandName === "format") {
    await interaction.deferReply({ ephemeral: false });
    const result = await formatLuau(code);
    let formattedCode = result.output || "";
    if (formattedCode.match("error: could not format file")) {
      formattedCode = code;
    }
    await reply(interaction, formattedCode, false, "lua");
  } else if (interaction.commandName === "bytecodeWOption") {
    createByteModal(interaction, code);
  } else if (interaction.commandName === "compileWOption") {
    createCompileModal(interaction, code);
  } else if (interaction.commandName === "compile") {
    await interaction.deferReply({ ephemeral: false });
    sendCompileRequestToRoblox(
      code,
      interaction.id,
      interaction.token,
      interaction.channelId,
      interaction.targetId,
      interaction,
    );
  }
}

module.exports = { handleContextMenu };
