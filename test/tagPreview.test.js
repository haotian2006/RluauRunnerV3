const test = require("node:test");
const assert = require("node:assert/strict");
const { ButtonBuilder, ButtonStyle } = require("discord.js");

const {
  TAG_PUBLISH_PREFIX,
  buildTagMessage,
  tagTitleFromSource,
} = require("../src/discord/tagRender");
const { getTagSourceFromContextMenu } = require("../src/discord/attachments");

const MARKDOWN = [
  "# Cool Tag",
  "",
  "prose that /tag shows",
  "--[[image: https://example.invalid/a.png]]",
  "",
  "```luau",
  "--[[name: Run Me]]",
  "print(1)",
  "```",
].join("\n");

function publishButton() {
  return new ButtonBuilder()
    .setCustomId(`${TAG_PUBLISH_PREFIX}uid`)
    .setLabel("Post publicly")
    .setStyle(ButtonStyle.Secondary);
}

test("tag markdown renders to an embed with run buttons", () => {
  const { embeds, components } = buildTagMessage(MARKDOWN, {
    displayName: tagTitleFromSource(MARKDOWN),
    url: "https://discord.invalid/msg",
  });

  assert.equal(embeds[0].data.title, "Cool Tag");
  assert.equal(embeds[0].data.image.url, "https://example.invalid/a.png");
  assert.match(embeds[0].data.description, /prose that \/tag shows/);
  // The image directive is a marker, not body text.
  assert.doesNotMatch(embeds[0].data.description, /image:/);
  assert.deepEqual(
    components[0].components.map((c) => c.data.label),
    ["Run Me"],
  );
});

test("the publish button gets its own row", () => {
  const { components } = buildTagMessage(MARKDOWN, {
    displayName: "preview",
    extraButtons: [publishButton()],
  });

  assert.equal(components.length, 2);
  assert.equal(components[1].components[0].data.label, "Post publicly");
});

test("run buttons leave room for the publish row", () => {
  const many = Array.from(
    { length: 30 },
    (_, i) => "```luau\n--[[name: b" + i + "]]\nprint(" + i + ")\n```",
  ).join("\n\n");

  const { components } = buildTagMessage(many, {
    displayName: "preview",
    extraButtons: [publishButton()],
  });

  assert.equal(components.length, 5);
  assert.deepEqual(
    components.map((row) => row.components.length),
    [5, 5, 5, 5, 1],
  );
});

test("a tag without a heading has no title of its own", () => {
  assert.equal(tagTitleFromSource("no heading here"), null);
});

test("preview source keeps prose and prefers an attached doc", async () => {
  const withoutAttachment = await getTagSourceFromContextMenu({
    targetMessage: { content: MARKDOWN, attachments: new Map() },
  });
  assert.equal(withoutAttachment, MARKDOWN);

  const oversized = {
    targetMessage: {
      content: MARKDOWN,
      attachments: new Map([
        [
          "0",
          {
            name: "tag.md",
            size: Number.MAX_SAFE_INTEGER,
            url: "https://example.invalid/tag.md",
          },
        ],
      ]),
    },
  };
  await assert.rejects(
    () => getTagSourceFromContextMenu(oversized),
    /over \d+ KB limit|over the \d+ KB limit/,
  );
});
