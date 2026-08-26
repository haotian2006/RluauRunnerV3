const fs = require("fs");
const path = require("path");

const { MAX_ROBLOX_WORKERS, ROOT_DIR } = require("./config");
const { logBot } = require("./log");

const PROFILES_DIR = path.join(ROOT_DIR, "profiles");

const LEGACY_ENV = [
  "UNIVERSE_ID",
  "PLACE_ID",
  "ROBLOX_API_KEY",
  "LUAU_MODULE",
  "BACK_UP_PATH",
  "BACK_UP_KEY",
  "BACKUP_LUAU_MODULE",
];

/**
 * @typedef {object} Profile
 * @property {string} name
 * @property {string} universeId
 * @property {string} placeId
 * @property {string} apiKey
 * @property {number} priority lower better
 * @property {boolean} enabled
 * @property {string} executeUrl
 */

function executeUrlFor(universeId, placeId) {
  return `https://apis.roblox.com/cloud/v2/universes/${universeId}/places/${placeId}/luau-execution-session-tasks`;
}

/**
 * @param {object} raw
 * @param {string} file
 * @returns {Profile}
 */
function validateProfile(raw, file) {
  const problems = [];
  for (const field of ["universeId", "placeId", "apiKey"]) {
    if (typeof raw[field] !== "string" || raw[field].trim() === "") {
      problems.push(`missing "${field}"`);
    }
  }
  if (raw.priority !== undefined && typeof raw.priority !== "number") {
    problems.push(`"priority" must be a number`);
  }
  if (problems.length) {
    throw new Error(`${file}: ${problems.join(", ")}`);
  }

  const universeId = String(raw.universeId);
  const placeId = String(raw.placeId);

  return {
    name:
      typeof raw.name === "string" && raw.name
        ? raw.name
        : path.basename(file, ".json"),
    universeId,
    placeId,
    apiKey: raw.apiKey,
    priority: typeof raw.priority === "number" ? raw.priority : 100,
    enabled: raw.enabled !== false,
    executeUrl: executeUrlFor(universeId, placeId),
  };
}

/** Files that could not be loaded, as human-readable reasons. */
const skipped = [];

/** Names of profiles present but turned off. */
const disabled = [];

/** @type {Profile[]|null} */
let cached = null;

function loadProfiles() {
  if (!fs.existsSync(PROFILES_DIR)) {
    return [];
  }
  const files = fs
    .readdirSync(PROFILES_DIR)
    .filter((f) => f.toLowerCase().endsWith(".json"));

  const profiles = [];
  for (const file of files) {
    const full = path.join(PROFILES_DIR, file);

    // A single malformed profile must not take the bot down: name it, skip it,
    // and keep running on whatever else is configured.
    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(full, "utf-8"));
    } catch (err) {
      skipped.push(`${file}: not valid JSON (${err.message})`);
      continue;
    }

    let profile;
    try {
      profile = validateProfile(raw, file);
    } catch (err) {
      skipped.push(err.message);
      continue;
    }

    if (profile.enabled) {
      profiles.push(profile);
    } else {
      disabled.push(profile.name);
    }
  }

  profiles.sort((a, b) => a.priority - b.priority);
  return profiles;
}

/**
 * Print what was loaded, what was skipped and why. Called once at startup so a
 * broken profile is visible instead of silently reducing the rotation.
 */
function reportProfiles() {
  const loaded = getProfiles();

  for (const reason of skipped) {
    console.error(`Profile skipped -> ${reason}`);
    logBot("Profile Error", reason);
  }
  if (disabled.length) {
    console.log(`Profiles disabled: ${disabled.join(", ")}`);
  }
  if (loaded.length) {
    console.log(
      `Loaded ${loaded.length} profile(s): ${loaded.map((p) => p.name).join(", ")}`,
    );
  }
  return { loaded, skipped, disabled };
}

function migrationHint() {
  const present = LEGACY_ENV.filter((k) => process.env[k]);
  const lines = [
    "No Roblox execution profiles found.",
    `Create profiles/primary.json describing the target place, for example:`,
    "",
    JSON.stringify(
      {
        name: "primary",
        universeId: process.env.UNIVERSE_ID || "<universe id>",
        placeId: process.env.PLACE_ID || "<place id>",
        apiKey: "<Open Cloud API key>",
        priority: 1,
        enabled: true,
      },
      null,
      2,
    ),
    "",
  ];
  if (present.length) {
    lines.push(
      `The old single-target variables (${present.join(", ")}) are no longer read.`,
      "Copy their values into a profile, then remove them from .env.",
    );
  }
  return lines.join("\n");
}

function getProfiles() {
  if (!cached) cached = loadProfiles();
  return cached;
}

function getMaxWorkers() {
  return Math.max(1, getProfiles().length) * MAX_ROBLOX_WORKERS;
}

module.exports = { getProfiles, getMaxWorkers, migrationHint, reportProfiles };
