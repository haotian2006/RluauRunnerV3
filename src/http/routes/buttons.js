const {
  ButtonValidationError,
  updateScriptButton,
} = require("../../discord/scriptButtons");
const { getSession } = require("../../core/sessions");
const { requireSecret } = require("../middleware");

function registerButtonRoutes(app) {
  app.patch("/button", requireSecret, async (req, res) => {
    try {
      // Web runs keep their buttons on their own responder, not in Discord state.
      const responder = getSession(req.body.token)?.responder;
      if (responder?.updateButton) await responder.updateButton(req.body);
      else await updateScriptButton(req.body.token, req.body);

      res.json({ message: "Button updated" });
    } catch (error) {
      if (error instanceof ButtonValidationError) {
        const status = error.message === "Interaction has expired" ? 410 : 400;
        return res.status(status).json({ message: error.message });
      }
      res.status(500).json({ message: `Failed to update button: ${error.message}` });
    }
  });
}

module.exports = { registerButtonRoutes };
