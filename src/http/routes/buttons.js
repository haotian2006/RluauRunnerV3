const { CompilingTasks, ScriptButtonCallbacks } = require("../../state");
const {
  MAX_BUTTONS,
  ButtonValidationError,
  componentsFromButtons,
  createButtonDefinition,
  updateButtonDefinition,
  validateId,
} = require("../../discord/scriptButtons");
const { retryDiscordOperation } = require("../../discord/reply");
const { requireSecret } = require("../middleware");

function registerButtonRoutes(app) {
  app.patch("/button", requireSecret, async (req, res) => {
    try {
      const { token, action } = req.body;
      const task = CompilingTasks[token];
      if (!task) {
        return res.status(410).json({ message: "Interaction has expired" });
      }
      if (!["create", "update", "delete"].includes(action)) {
        throw new ButtonValidationError("Unknown button action");
      }

      const interaction = task[0];
      const currentButtons = task[7] ?? new Map();
      const nextButtons = new Map(currentButtons);
      const buttonId = validateId(req.body.buttonId, "buttonId");
      const existing = currentButtons.get(buttonId);
      let definition;

      if (action === "create") {
        if (existing) {
          throw new ButtonValidationError("Button already exists");
        }
        if (ScriptButtonCallbacks.has(buttonId)) {
          throw new ButtonValidationError("Button id collision");
        }
        if (currentButtons.size >= MAX_BUTTONS) {
          throw new ButtonValidationError(
            `A response can contain at most ${MAX_BUTTONS} buttons`,
          );
        }
        definition = createButtonDefinition(req.body, interaction.user.id);
        nextButtons.set(buttonId, definition);
      } else {
        if (!existing) {
          throw new ButtonValidationError("Button does not exist");
        }
        if (action === "update") {
          definition = updateButtonDefinition(existing, req.body);
          nextButtons.set(buttonId, definition);
        } else {
          validateId(req.body.processId, "processId");
          if (req.body.processId !== existing.processId) {
            throw new ButtonValidationError(
              "Button belongs to a different process",
            );
          }
          nextButtons.delete(buttonId);
        }
      }

      await retryDiscordOperation(
        () =>
          interaction.editReply({
            components: componentsFromButtons(nextButtons),
          }),
        3,
        "Edit script buttons",
      );

      task[7] = nextButtons;
      if (action === "delete") {
        ScriptButtonCallbacks.delete(buttonId);
      } else {
        ScriptButtonCallbacks.set(buttonId, {
          token,
          processId: definition.processId,
          ownerUserId: definition.ownerUserId,
          ownerOnly: definition.ownerOnly,
        });
      }

      res.json({ message: "Button updated" });
    } catch (error) {
      if (error instanceof ButtonValidationError) {
        return res.status(400).json({ message: error.message });
      }
      res.status(500).json({ message: `Failed to update button: ${error.message}` });
    }
  });
}

module.exports = { registerButtonRoutes };
