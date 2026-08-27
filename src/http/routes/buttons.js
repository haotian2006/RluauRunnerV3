const {
  ButtonValidationError,
  updateScriptButton,
} = require("../../discord/scriptButtons");
const { requireSecret } = require("../middleware");

function registerButtonRoutes(app) {
  app.patch("/button", requireSecret, async (req, res) => {
    try {
      await updateScriptButton(req.body.token, req.body);

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
