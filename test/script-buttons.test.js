const test = require("node:test");
const assert = require("node:assert/strict");

const {
  SCRIPT_BUTTON_PREFIX,
  updateScriptButton,
} = require("../src/discord/scriptButtons");
const { handleScriptButton } = require("../src/discord/handlers/button");
const { CompilingTasks, ScriptButtonCallbacks } = require("../src/state");

test("shared button service routes Lune clicks and preserves lifecycle", async () => {
  const token = `button-service:${Date.now()}`;
  const buttonId = `button-${Date.now()}`;
  const processId = `process-${Date.now()}`;
  const edits = [];
  const clicks = [];
  const interaction = {
    user: { id: "owner" },
    async editReply(options) {
      edits.push(options);
    },
  };
  CompilingTasks[token] = [
    interaction,
    null,
    null,
    0,
    null,
    null,
    new Map(),
    new Map(),
  ];

  try {
    await updateScriptButton(
      token,
      {
        action: "create",
        buttonId,
        processId,
        label: "Run",
        style: "Success",
      },
      (click) => clicks.push(click),
    );

    await handleScriptButton({
      customId: SCRIPT_BUTTON_PREFIX + buttonId,
      user: { id: "owner", username: "tester" },
      isButton: () => true,
      async deferUpdate() {},
    });
    assert.deepEqual(clicks, [
      { buttonId, userId: "owner", username: "tester" },
    ]);

    await updateScriptButton(token, {
      action: "update",
      buttonId,
      processId,
      disabled: true,
    });
    assert.equal(CompilingTasks[token][7].get(buttonId).disabled, true);
    assert.equal(typeof ScriptButtonCallbacks.get(buttonId).onClick, "function");

    await updateScriptButton(token, {
      action: "delete",
      buttonId,
      processId,
    });
    assert.equal(CompilingTasks[token][7].has(buttonId), false);
    assert.equal(ScriptButtonCallbacks.has(buttonId), false);
    assert.equal(edits.length, 3);
  } finally {
    ScriptButtonCallbacks.delete(buttonId);
    delete CompilingTasks[token];
  }
});
