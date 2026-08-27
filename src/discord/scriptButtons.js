const {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} = require("discord.js");

const { CompilingTasks, ScriptButtonCallbacks } = require("../state");
const { retryDiscordOperation } = require("./reply");

const SCRIPT_BUTTON_PREFIX = "rluau_button:";
const MAX_BUTTONS = 25;
const MAX_LABEL_LENGTH = 80;
const ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const STYLES = new Map([
  ["primary", { name: "Primary", value: ButtonStyle.Primary }],
  ["secondary", { name: "Secondary", value: ButtonStyle.Secondary }],
  ["success", { name: "Success", value: ButtonStyle.Success }],
  ["danger", { name: "Danger", value: ButtonStyle.Danger }],
]);

class ButtonValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ButtonValidationError";
  }
}

function validateId(value, field) {
  if (typeof value !== "string" || !ID_PATTERN.test(value)) {
    throw new ButtonValidationError(`${field} is invalid`);
  }
  return value;
}

function normalizeLabel(value, required) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string") {
    throw new ButtonValidationError("Label must be a string");
  }
  const label = value.trim();
  if (!label || label.length > MAX_LABEL_LENGTH) {
    throw new ButtonValidationError(
      `Label must contain 1-${MAX_LABEL_LENGTH} characters`,
    );
  }
  return label;
}

function normalizeStyle(value, required) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string") {
    throw new ButtonValidationError("Style must be a string");
  }
  const style = STYLES.get(value.toLowerCase());
  if (!style) {
    throw new ButtonValidationError(
      "Style must be Primary, Secondary, Success, or Danger",
    );
  }
  return style.name;
}

function createButtonDefinition(body, ownerUserId) {
  return {
    id: validateId(body.buttonId, "buttonId"),
    processId: validateId(body.processId, "processId"),
    ownerUserId,
    ownerOnly: body.ownerOnly !== false,
    label: normalizeLabel(body.label, true),
    style: normalizeStyle(body.style ?? "Primary", true),
    disabled: body.disabled === true,
  };
}

function updateButtonDefinition(existing, body) {
  validateId(body.processId, "processId");
  if (body.processId !== existing.processId) {
    throw new ButtonValidationError("Button belongs to a different process");
  }
  const label = normalizeLabel(body.label, false);
  const style = normalizeStyle(body.style, false);
  return {
    ...existing,
    ...(label !== undefined && { label }),
    ...(style !== undefined && { style }),
    ...(typeof body.disabled === "boolean" && { disabled: body.disabled }),
    ...(typeof body.ownerOnly === "boolean" && {
      ownerOnly: body.ownerOnly,
    }),
  };
}

function componentsFromButtons(buttonMap) {
  const definitions = [...buttonMap.values()];
  const rows = [];
  for (let i = 0; i < definitions.length; i += 5) {
    const row = new ActionRowBuilder();
    row.addComponents(
      definitions.slice(i, i + 5).map((definition) => {
        const style = STYLES.get(definition.style.toLowerCase());
        return new ButtonBuilder()
          .setCustomId(SCRIPT_BUTTON_PREFIX + definition.id)
          .setLabel(definition.label)
          .setStyle(style.value)
          .setDisabled(definition.disabled);
      }),
    );
    rows.push(row);
  }
  return rows;
}

function cleanupScriptButtons(buttonMap) {
  if (!buttonMap) return;
  for (const buttonId of buttonMap.keys()) {
    ScriptButtonCallbacks.delete(buttonId);
  }
  buttonMap.clear();
}

async function updateScriptButton(token, body, onClick = null) {
  const task = CompilingTasks[token];
  if (!task) {
    throw new ButtonValidationError("Interaction has expired");
  }
  if (!["create", "update", "delete"].includes(body.action)) {
    throw new ButtonValidationError("Unknown button action");
  }

  const interaction = task[0];
  const currentButtons = task[7] ?? new Map();
  const nextButtons = new Map(currentButtons);
  const buttonId = validateId(body.buttonId, "buttonId");
  const existing = currentButtons.get(buttonId);
  let definition;

  if (body.action === "create") {
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
    definition = createButtonDefinition(body, interaction.user.id);
    nextButtons.set(buttonId, definition);
  } else {
    if (!existing) {
      throw new ButtonValidationError("Button does not exist");
    }
    if (body.action === "update") {
      definition = updateButtonDefinition(existing, body);
      nextButtons.set(buttonId, definition);
    } else {
      validateId(body.processId, "processId");
      if (body.processId !== existing.processId) {
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
  if (body.action === "delete") {
    ScriptButtonCallbacks.delete(buttonId);
  } else {
    const previous = ScriptButtonCallbacks.get(buttonId);
    ScriptButtonCallbacks.set(buttonId, {
      token,
      processId: definition.processId,
      ownerUserId: definition.ownerUserId,
      ownerOnly: definition.ownerOnly,
      onClick: onClick || previous?.onClick || null,
    });
  }
}

module.exports = {
  SCRIPT_BUTTON_PREFIX,
  MAX_BUTTONS,
  ButtonValidationError,
  validateId,
  createButtonDefinition,
  updateButtonDefinition,
  updateScriptButton,
  componentsFromButtons,
  cleanupScriptButtons,
};
