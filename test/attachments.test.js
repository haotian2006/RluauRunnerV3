const test = require("node:test");
const assert = require("node:assert/strict");

const { getCodeFromContextMenu } = require("../src/discord/attachments");

test("context-menu attachment failures do not execute message text", async () => {
  const interaction = {
    targetMessage: {
      content: "print('message fallback')",
      attachments: {
        first() {
          return {
            name: "script.lua",
            size: Number.MAX_SAFE_INTEGER,
            url: "https://example.invalid/script.lua",
          };
        },
      },
    },
  };

  await assert.rejects(
    () => getCodeFromContextMenu(interaction),
    /over the \d+ KB limit/,
  );
});
