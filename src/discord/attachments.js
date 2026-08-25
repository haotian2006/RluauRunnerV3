const {
  MAX_DOWNLOAD_BYTES,
  fetchBinaryFile,
  fetchFileContent,
} = require("../fetchFile");

const TEXT_EXTENSIONS = [".txt", ".lua", ".luau", ".json"];

/** Discord reports the size up front; reject before spending a request on it. */
function isTooLarge(attachment) {
  return (
    typeof attachment.size === "number" && attachment.size > MAX_DOWNLOAD_BYTES
  );
}

function tooLargeMessage(attachment) {
  return `\`${attachment.name}\` is ${Math.floor(
    attachment.size / 1024,
  )} KB, over the ${Math.floor(MAX_DOWNLOAD_BYTES / 1024)} KB limit`;
}

/**
 * Read an attachment as text, or null when its name says it is not a text
 * file we know how to read. Throws when the file is over the size cap.
 */
async function checkAndGetAttachmentText(attachment) {
  const isTextFile = TEXT_EXTENSIONS.some((ext) =>
    attachment.name.toLowerCase().endsWith(ext),
  );

  if (!isTextFile) {
    return null;
  }
  if (isTooLarge(attachment)) {
    throw new Error(tooLargeMessage(attachment));
  }
  return await fetchFileContent(attachment.url);
}

async function getInputsFromContext(interaction) {
  const content = interaction.targetMessage.content;
  const attachments = interaction.targetMessage.attachments;

  if (attachments.size === 0) {
    return { inputs: [content], failures: [] };
  }

  const inputs = [];
  const failures = [];
  for (const attachment of attachments.values()) {
    if (isTooLarge(attachment)) {
      failures.push(tooLargeMessage(attachment));
      continue;
    }
    try {
      inputs.push(await fetchBinaryFile(attachment.url));
    } catch (err) {
      failures.push(`\`${attachment.name}\`: ${err.message}`);
    }
  }
  return { inputs, failures };
}

/**
 * Extract the code to run from a targeted message
 *
 * @param {import('discord.js').MessageContextMenuCommandInteraction} interaction
 * @returns {Promise<string>}
 */
async function getCodeFromContextMenu(interaction) {
  let content = interaction.targetMessage.content;
  const attachment = interaction.targetMessage.attachments.first();

  const regex = /```\w*\s*([\s\S]*?)\s*```/g;
  const codeBlocks = [...content.matchAll(regex)].map((m) => m[1].trim());
  if (attachment && attachment.url) {
    let data = null;
    try {
      data = await checkAndGetAttachmentText(attachment);
    } catch {
      data = null;
    }

    if (data) {
      content = data;
      codeBlocks.unshift(content);
    }
  }

  if (codeBlocks.length === 0) {
    return content;
  }
  let code = codeBlocks[0];
  for (let i = 1; i < codeBlocks.length; i++) {
    const additionalCode = codeBlocks[i];
    if (additionalCode.includes("{CODE}")) {
      code = additionalCode.replace(/{CODE}/g, code);
    } else {
      code = code + "\n" + additionalCode;
    }
  }
  code = code.replace(
    /--\[==\[IGNORE START\]==\][\s\S]*?--\[==\[IGNORE END\]==\]/g,
    "",
  );
  return code;
}

module.exports = { getInputsFromContext, getCodeFromContextMenu };
