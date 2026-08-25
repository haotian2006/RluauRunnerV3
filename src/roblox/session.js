const {
  SERVER_CHECK_INTERVAL,
  SERVER_CREATION_COOL_DOWN,
  SERVER_PING_TIMEOUT,
  SERVER_RUN_TIME_MAX,
  SERVER_TIME_OUT,
  botSrcEncoded,
} = require("../config");
const { log, logBot } = require("../log");
const { getProfiles } = require("../profiles");
const {
  CompilingTasks,
  ExecuteTasks,
  SECRET_TOKEN,
  state,
} = require("../state");
const { wait } = require("../util");
const { closeSession } = require("../core/sessions");
const { cleanupScriptButtons } = require("../discord/scriptButtons");

function bootstrapScript() {
  return `local EncodingService = game:GetService("EncodingService")

  local str = [[${botSrcEncoded}]]
  local decoded = EncodingService:Base64Decode(buffer.fromstring(str))
  decoded = EncodingService:DecompressBuffer(decoded,Enum.CompressionAlgorithm.Zstd)
  local Instances =  game:GetService("SerializationService"):DeserializeInstancesAsync(decoded)
  local module = Instances[1]

     require(module).start("${state.CallbackUrl}", "${SECRET_TOKEN}")
`;
}

async function startRoblox(profile) {
  state.LastServerCreation = Date.now();

  let res;
  try {
    res = await fetch(profile.executeUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": profile.apiKey,
      },
      body: JSON.stringify({
        script: bootstrapScript(),
        timeout: SERVER_TIME_OUT,
      }),
    });
  } catch (err) {
    console.log(
      `Failed to reach Roblox for profile ${profile.name}:`,
      err.message,
    );
    log(
      "0",
      "BOT",
      "Failed to start Roblox",
      `${profile.name}: ${err.message}`,
    );
    return false;
  }

  if (!res.ok) {
    console.log(
      `Failed to start Roblox with profile ${profile.name}: `,
      res.statusText,
    );
    log(
      "0",
      "BOT",
      "Failed to start Roblox",
      `${profile.name}: ${res.statusText}`,
    );
    return false;
  }

  state.SERVERS_CREATED++;
  setTimeout(() => {
    state.SERVERS_CREATED--;
  }, 90000);
  return true;
}

/**
 * How long to wait between session creations. Backs off when many sessions
 * have been created recently.
 */
function creationDebounce() {
  if (state.SERVERS_CREATED <= 2) {
    return SERVER_CREATION_COOL_DOWN / 1.5;
  }
  if (state.SERVERS_CREATED >= 5) {
    return SERVER_CREATION_COOL_DOWN * 1.5;
  }
  return SERVER_CREATION_COOL_DOWN;
}

let nextProfileIndex = 0;

function profileAttemptOrder(profiles, startIndex) {
  return profiles.map((profile, offset) => {
    const index = (startIndex + offset) % profiles.length;
    return { profile: profiles[index], index };
  });
}

async function startAnyProfile() {
  const profiles = getProfiles();
  if (profiles.length === 0) {
    logBot("Roblox Server", "No profiles configured; cannot start a session.");
    return false;
  }

  const startIndex = nextProfileIndex % profiles.length;
  const candidates = profileAttemptOrder(profiles, startIndex);

  for (const [attempt, candidate] of candidates.entries()) {
    const { profile, index } = candidate;
    const started = await startRoblox(profile);
    if (started) {
      nextProfileIndex = (index + 1) % profiles.length;
      return true;
    }
    if (attempt < candidates.length - 1) {
      logBot(
        "Roblox Server",
        `Profile ${profile.name} failed, trying the next one...`,
      );
    }
  }

  nextProfileIndex = (startIndex + 1) % profiles.length;
  return false;
}

function failPendingTasks() {
  Object.keys(ExecuteTasks).forEach((key) => {
    const task = ExecuteTasks[key];
    if (!task) return;
    if (!CompilingTasks || !CompilingTasks[task.token]) return;
    const [interaction] = CompilingTasks[task.token];
    if (interaction) {
      try {
        interaction.editReply({
          content: `Failed to start Roblox server.`,
          ephemeral: true,
        });
      } catch (error) {}
      delete ExecuteTasks[key];
      clearTimeout(CompilingTasks[task.token]?.[5]);
      cleanupScriptButtons(CompilingTasks[task.token]?.[7]);
      closeSession(task.token);
      delete CompilingTasks[task.token];
    }
  });
}

async function checkRobloxServer() {
  while (true) {
    const hasTask = Object.keys(ExecuteTasks).length > 0;
    const serverTimeout =
      Date.now() - state.RunningServerTime > SERVER_RUN_TIME_MAX;
    const pingTimeout = Date.now() - state.LastServerPing > SERVER_PING_TIMEOUT;
    const lastCreationDebounce =
      Date.now() - state.LastServerCreation > creationDebounce();

    if (hasTask && (serverTimeout || pingTimeout) && lastCreationDebounce) {
      console.log("Starting new Roblox server...");
      logBot("Roblox Server", "Starting new Roblox server...");

      if (!(await startAnyProfile())) {
        failPendingTasks();
      }
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

module.exports = { checkRobloxServer, profileAttemptOrder };
