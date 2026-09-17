const {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  EmbedBuilder,
} = require("discord.js");

const {
  extractDocCodeBlocks,
  extractDocImages,
  stripNoShowForDisplay,
} = require("../filter");
const { docCodeStore } = require("../state");
const { generateUUID } = require("../util");

const DOC_CODE_TTL_MS = 1000 * 60 * 10;
const MAX_EMBED_DESCRIPTION = 4096;
const TAG_PUBLISH_PREFIX = "tag_pub:";
const MAX_ROWS = 5;
const BUTTONS_PER_ROW = 5;

function buildTagComponents(codeBlocks, extraButtons = []) {
  const components = [];
  // Discord allows five rows total, so an extra row of our own costs one row
  // of run buttons.
  const maxCodeRows = extraButtons.length ? MAX_ROWS - 1 : MAX_ROWS;
  const runnable = codeBlocks.slice(0, maxCodeRows * BUTTONS_PER_ROW);

  const uuids = runnable.map((block) => {
    const uuid = generateUUID();
    docCodeStore[uuid] =
      `log("Running: ${block.label}", "cyan", true)\n${block.code}`;
    // Unref'd so a pending eviction never holds the process open.
    setTimeout(() => {
      delete docCodeStore[uuid];
    }, DOC_CODE_TTL_MS).unref?.();
    return uuid;
  });

  for (let i = 0; i < runnable.length; i += BUTTONS_PER_ROW) {
    const row = new ActionRowBuilder();
    const slice = runnable.slice(i, i + BUTTONS_PER_ROW);
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

  if (extraButtons.length) {
    components.push(
      new ActionRowBuilder().addComponents(
        extraButtons.slice(0, BUTTONS_PER_ROW),
      ),
    );
  }
  return components;
}

/**
 * Render tag markdown into the embeds and run buttons /tag posts.
 *
 * @param {string} text raw markdown
 * @param {{displayName?: string, url?: string, extraButtons?: import('discord.js').ButtonBuilder[]}} options
 */
function buildTagMessage(text, { displayName, url, extraButtons } = {}) {
  const displayText = stripNoShowForDisplay(text).trim();
  const embed = new EmbedBuilder()
    .setTitle(displayName || "Tag")
    .setDescription(
      (displayText.length > MAX_EMBED_DESCRIPTION
        ? displayText.substring(0, MAX_EMBED_DESCRIPTION - 3) + "..."
        : displayText) || null,
    )
    .setColor(0x5865f2);
  if (url) embed.setURL(url);

  const [firstImage, ...moreImages] = extractDocImages(text).slice(0, 4);
  if (firstImage) embed.setImage(firstImage);

  // Discord only stacks the extra images under the first embed when every
  // embed shares a URL, so a tag without one renders them separately.
  const embeds = [
    embed,
    ...moreImages.map((image) => {
      const extra = new EmbedBuilder().setImage(image);
      if (url) extra.setURL(url);
      return extra;
    }),
  ];

  return {
    embeds,
    components: buildTagComponents(extractDocCodeBlocks(text), extraButtons),
  };
}

/** First markdown heading of a tag, used as its title when there is no file. */
function tagTitleFromSource(text) {
  const heading = text.match(/^\s*#+\s*(.+)$/m);
  if (!heading) return null;
  return heading[1].replace(/\*/g, "").trim().slice(0, 256) || null;
}

module.exports = {
  TAG_PUBLISH_PREFIX,
  buildTagMessage,
  tagTitleFromSource,
};
