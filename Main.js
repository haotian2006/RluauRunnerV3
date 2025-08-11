const {
  Client,
  GatewayIntentBits,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
  ActionRowBuilder,
} = require("discord.js");
const { https } = require("follow-redirects");
const fs = require("fs");
const path = require("path");
const axios = require("axios");
const express = require("express");
const { console } = require("inspector");
require("dotenv").config();

const LUAU_DOWNLOAD_URL =
  "https://github.com/haotian2006/luaufork/releases/latest/download/LuauCompile.Web.js";
const DISCORD_TOKEN = process.env.BOT_TOKEN;
const DISCORD_APP_ID = process.env.CLIENT_ID;
const ROBLOX_API_KEY = process.env.ROBLOX_API_KEY;
const UNIVERSE_ID = process.env.UNIVERSE_ID;
const PLACE_ID = process.env.PLACE_ID;
const PORT = process.env.PORT || 3000;
const KONST_API = "http://api.plusgiant5.com";
const EXECUTE_LUAU = `https://apis.roblox.com/cloud/v2/universes/${UNIVERSE_ID}/places/${PLACE_ID}/luau-execution-session-tasks`;
const TUNNEL_URL = process.env.TUNNEL_URL;
const FORM_URL = process.env.FORMURL;

const SERVER_CREATION_COOL_DOWN = 1000 * 10;
const SERVER_RUN_TIME_MAX = 1000 * 60 * 3;
const SERVER_CHECK_INTERVAL = 1000;
const SERVER_PING_TIMEOUT = 1000 * 5;

let IP = "";
let RunningServer = "";
let RunningServerTime = 0;
let LastServerPing = 0;

let LastServerCreation = 0;

const ExecuteTasks = {};
const app = express();
app.use(express.json());
const client = new Client({
  intents: [GatewayIntentBits.Guilds],
});

const luauFilePath = path.resolve("./LuauCompile.Web.js");
let luauModule;

function generateUUID() {
  return Math.random().toString(36).substring(2, 10);
}

function log(userid, name, commandName, data) {
  if (data) {
    if (typeof data === "string" && data.length > 20000 - 10) {
      data = data.substring(0, 20000 - 10) + "... [truncated]";
    }
  }
  axios
    .post(
      FORM_URL,
      new URLSearchParams({
        "entry.1569623480": name,
        "entry.1249804528": userid,
        "entry.726094871": commandName,
        "entry.182293982": data ? data : "",
      }),
      {
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
      }
    )
    .catch(() => {});
}

https
  .get(LUAU_DOWNLOAD_URL, async (res) => {
    if (res.statusCode !== 200) {
      console.log(`Failed to get '${LUAU_DOWNLOAD_URL}' (${res.statusCode})`);
      log("0", "BOT", "Failed to get Luau", res.statusCode);
      luauModule = require(luauFilePath);
      return;
    }
    const file = fs.createWriteStream(luauFilePath);
    res.pipe(file);
    file.on("finish", async () => {
      file.close(async () => {
        console.log("Luau downloaded successfully.");
        const modulePath = path.resolve("./LuauCompile.Web.js");
        luauModule = await import(`file://${modulePath}`);
        luauModule = luauModule.default;
        console.log("Luau compiler loaded successfully.");
      });
    });
  })

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function startRoblox() {
  let script = `require(workspace.LuauBot).start("${IP}") task.wait(300)`;
  LastServerCreation = Date.now();
  const res = await fetch(EXECUTE_LUAU, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ROBLOX_API_KEY,
    },
    body: JSON.stringify({
      script: script,
    }),
  });
  if (!res.ok) {
    console.log("Failed to start Roblox: ", res.statusText);
    log("0", "BOT", "Failed to start Roblox", res.statusText);
  }

  return true;
}

function fetchFileContent(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (response) => {
        let data = "";

        if (response.statusCode !== 200) {
          reject(
            new Error(`Failed to get data. Status Code: ${response.statusCode}`)
          );
          return;
        }

        response.on("data", (chunk) => {
          data += chunk;
        });

        response.on("end", () => {
          resolve(data);
        });
      })
      .on("error", (err) => {
        reject(err);
      });
  });
}

async function kCall(api, bytecode) {
  let replies = 5;
  let content = "";
  while (replies > 0) {
    try {
      const response = await fetch(`${KONST_API}/konstant/${api}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: bytecode,
      });
      if (!response.ok) {
        throw new Error(`HTTP error! Status: ${response.status}`);
      } else if (response.status !== 200) {
        throw new Error(`Error while requesting`);
      } else {
        content = await response.text();
        return content;
      }
    } catch (error) {
      replies--;
      if (replies === 0) {
        content = "Max retries reached: " + error.message;
      }
      await wait(500);
    }
  }
  return content;
}

/**
 * @param {string?} code
 */
function getByteCodeOptions(code) {
  if (!code) {
    code = "";
  }
  const oMatch = code.match("--!optimize (\\d+)");
  const dMatch = code.match("--!debug (\\d+)");
  let options = {
    binary: code.indexOf("--!binary") !== -1,
    remarks: code.indexOf("--!remarks") !== -1,
    optimizeLevel: oMatch ? parseInt(oMatch[1]) : 2,
    debugLevel: dMatch ? parseInt(dMatch[1]) : 0,
  };
  options.optimizeLevel = Math.max(0, Math.min(2, options.optimizeLevel));
  options.debugLevel = Math.max(0, Math.min(2, options.debugLevel));
  return options;
}

function byteCodeOptionsToString(options) {
  let str = "";
  if (options.remarks && !options.binary) {
    str += "Remarks: Enabled\n";
  }
  str += `OptimizeLevel: ${options.optimizeLevel}\n`;
  str += `DebugLevel: ${options.debugLevel}\n`;
  str += "-------------------\n";
  return str;
}

function getByteCode(options, code) {
  let optionStr = "-a ";
  if (options.remarks) {
    optionStr += "--remarks ";
  }
  if (options.binary) {
    optionStr += "--binary ";
  }
  optionStr += `-O${options.optimizeLevel} -g${options.debugLevel}`;

  let pointer = luauModule.ccall(
    "exportCompileRaw",
    "number",
    ["string", "string"],
    [optionStr, code]
  );
  const size = luauModule.ccall("getSize", "number", [], []);
  const bytes = new Uint8Array(luauModule.HEAPU8.buffer, pointer, size);
  const decoder = new TextDecoder("utf-8");
  const str = decoder.decode(bytes);
  return str;
}

/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} interaction
 */
async function getCodeFromContextMenu(interaction) {
  let content = interaction.targetMessage.content;
  const attachments = interaction.targetMessage.attachments.first();
  if (attachments && attachments.url) {
    content = await fetchFileContent(attachments.url);
  } else {
    const match = content.match(/```(?:lua)?\s*([\s\S]*?)\s*```/);
    content = match ? match[1] : content;
  }
  return content;
}

const byteCodeModalData = {};
/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} data
 * @param {string} code
 */
async function createByteModal(data, code) {
  const msgLink = `https://discord.com/channels/@me/${data.channelId}/${data.targetId}`;

  const modal = new ModalBuilder()
    .setCustomId("bytecode_modal")
    .setTitle("Generate Bytecode");

  const optimizeInput = new TextInputBuilder()
    .setCustomId("optimize_level")
    .setLabel("Optimize Level (0-2)")
    .setStyle(TextInputStyle.Short)
    .setValue("2")
    .setRequired(true);

  const debugInput = new TextInputBuilder()
    .setCustomId("debug_level")
    .setLabel("Debug Level (0-2)")
    .setStyle(TextInputStyle.Short)
    .setValue("2")
    .setRequired(true);

  const useKonst = new TextInputBuilder()
    .setCustomId("konst")
    .setLabel("Use Konst? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const remarksInput = new TextInputBuilder()
    .setCustomId("remarks")
    .setLabel("Enable Remarks? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const ephemeralInput = new TextInputBuilder()
    .setCustomId("ephemeral")
    .setLabel("Hide Text? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  modal.addComponents(
    new ActionRowBuilder().addComponents(optimizeInput),
    new ActionRowBuilder().addComponents(debugInput),
    new ActionRowBuilder().addComponents(useKonst),
    new ActionRowBuilder().addComponents(remarksInput),
    new ActionRowBuilder().addComponents(ephemeralInput)
  );

  byteCodeModalData[data.user.id] = {
    data: data,
    content: code,
    msgLink: msgLink,
  };
  await data.showModal(modal);

  await wait(5 * 60 * 1000);
  delete byteCodeModalData[data.user.id];
}

async function reply(
  interaction,
  content,
  ephemeral = false,
  fileType = "lua"
) {
  const len = content.length;
  if (len > 1900) {
    interaction.editReply({
      content: "Output too long sending as a file...",
      files: [
        {
          name: "output." + fileType,
          attachment: Buffer.from(content, "utf-8"),
        },
      ],
      ephemeral: ephemeral,
    });
  } else {
    await interaction.editReply({
      content: "```" + `${fileType}\n` + content + "\n```",
      ephemeral: ephemeral,
    });
  }
}

async function sendCompileRequestToRoblox(
  code,
  interactionId,
  interactionToken,
  channelId,
  targetId
) {
  const uuid = generateUUID();
  ExecuteTasks[uuid] = {
    content: code,
    channelId: channelId,
    targetId: targetId,
    id: interactionId,
    token: interactionToken,
  };
}

app.patch("/respond", async (req, res) => {
  try {
    const token = req.body.token;
    const responseContent = req.body.data;
    const url = `https://discord.com/api/v10/webhooks/${DISCORD_APP_ID}/${token}/messages/@original`;
    const response = await axios.patch(url, responseContent, {
      headers: {
        Authorization: `Bot ${DISCORD_TOKEN}`,
        "Content-Type": "application/json",
      },
    });
    res.json({
      message: "Successfully sent response to Discord",
      data: response.data,
    });
  } catch (error) {
    res.status(500).json({
      message: "Failed to send response to Discord",
      error: error.response ? error.response.data : error.message,
    });
  }
});

app.get('/', (req, res) => {
  res.send('Bot is running!');
});

app.post("/start", async (req, res) => {
  RunningServer = req.body.ServerId;
  RunningServerTime = Date.now();
  res.json({ message: "Server started" });
});

app.post("/ping", (req, res) => {
  if (req.body.ServerId === RunningServer) {
    LastServerPing = Date.now();
  }
  res.json({ message: "Ping received" });
});
app.post("/getAll", async (req, res) => {
  const ServerId = req.body.ServerId;

  if (ServerId === RunningServer) {
    LastServerPing = Date.now();
    const Ids = [];
    for (const id in ExecuteTasks) {
      Ids.push(id);
    }
    res.json(Ids);
  } else {
    res.status(201).json({ message: "New Session" });
  }
});

app.post("/get", async (req, res) => {
  const TaskId = req.body.TaskId;
  if (TaskId in ExecuteTasks) {
    res.json(ExecuteTasks[TaskId]);
    delete ExecuteTasks[TaskId];
    return;
  }
  res.status(404).json({ message: "Task not found" });
});

app.post("/test", async (req, res) => {
  console.log("Test endpoint hit", req.body[0]);
  res.json({ message: "Test endpoint response" });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Server is running on port ${PORT}`);
});

async function checkRobloxServer() {
  while (true) {
    const hasTask = Object.keys(ExecuteTasks).length > 0;
    const serverTimeout = Date.now() - RunningServerTime > SERVER_RUN_TIME_MAX;
    const pingTimeout = Date.now() - LastServerPing > SERVER_PING_TIMEOUT;
    const lastCreationDebounce =
      Date.now() - LastServerCreation > SERVER_CREATION_COOL_DOWN;
    if (hasTask && (serverTimeout || pingTimeout) && lastCreationDebounce) {
      console.log("Starting new Roblox server...");
      await startRoblox();
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

async function main() {
  while (!luauModule || !luauModule.HEAPU8) {
    await wait(100);
  }

  console.log("Luau compiler is ready to use.");
  const res = await fetch("https://api.ipify.org?format=json");
  const data = await res.json();
  IP = `${data.ip}:${PORT}`;
  if (TUNNEL_URL) {
    IP = TUNNEL_URL;
  }

  client.on("interactionCreate", async (interaction) => {
    if (interaction.isMessageContextMenuCommand()) {
      const code = await getCodeFromContextMenu(interaction);
      log(
        interaction.user.id,
        interaction.user.username,
        interaction.commandName,
        code
      );
      if (interaction.commandName === "bytecode") {
        await interaction.deferReply({ ephemeral: false });
        const options = getByteCodeOptions(code);
        const bytecode =
          byteCodeOptionsToString(options) + getByteCode(options, code);
        await reply(interaction, bytecode, false, "Stylus");
      } else if (
        interaction.commandName === "bytecodeK" ||
        interaction.commandName === "decompile"
      ) {
        await interaction.deferReply({ ephemeral: false });
        const api =
          interaction.commandName === "bytecodeK" ? "disassemble" : "decompile";
        const options = getByteCodeOptions(code);
        options.remarks = false;
        options.binary = true;
        const bytecode = getByteCode(options, code);

        const bytecodeK = await kCall(api, bytecode);
        reply(interaction, byteCodeOptionsToString(options) + bytecodeK);
      } else if (interaction.commandName === "bytecodeWOption") {
        createByteModal(interaction, code);
      } else if (interaction.commandName === "compile") {
        await interaction.deferReply({ ephemeral: false });
        sendCompileRequestToRoblox(
          code,
          interaction.id,
          interaction.token,
          interaction.channelId,
          interaction.targetId
        );
      }
    } else if (interaction.isModalSubmit()) {
      if (interaction.customId === "bytecode_modal") {
        const info = byteCodeModalData[interaction.user.id];
        if (!info) return;
        const options = getByteCodeOptions();
        options.remarks =
          interaction.fields.getTextInputValue("remarks") === "1";
        options.optimizeLevel =
          parseInt(
            interaction.fields.getTextInputValue("optimize_level"),
            10
          ) || 0;
        options.debugLevel =
          parseInt(interaction.fields.getTextInputValue("debug_level"), 10) ||
          0;

        const ephemeral =
          interaction.fields.getTextInputValue("ephemeral") === "1";
        const useKonst = interaction.fields.getTextInputValue("konst") === "1";
        options.binary = useKonst;

        let bytecode = getByteCode(options, info.content);
        let type = "Stylus";
        if (useKonst) {
          bytecode = await kCall("disassemble", bytecode);
          type = "lua";
        }
        await interaction.deferReply({ ephemeral: ephemeral });

        reply(
          interaction,
          byteCodeOptionsToString(options) + bytecode,
          ephemeral,
          type
        );

        delete byteCodeModalData[interaction.user.id];
      }
    } else if (interaction.isCommand()) {
      if (interaction.commandName === "ping") {
        const sent = await interaction.reply({
          content: "Pinging...",
          fetchReply: true,
        });
        const diff = sent.createdTimestamp - interaction.createdTimestamp;
        log(
          interaction.user.id,
          interaction.user.username,
          interaction.commandName,
          `Pong! ${diff}ms.`
        );
        await interaction.editReply(`Pong! ${diff}ms.`);
      } else if (interaction.commandName === "compile") {
        await interaction.deferReply({ ephemeral: false });
        const code = interaction.options.getString("code");
        log(
          interaction.user.id,
          interaction.user.username,
          interaction.commandName,
          code
        );
        sendCompileRequestToRoblox(
          code,
          interaction.id,
          interaction.token,
          interaction.channelId,
          interaction.targetId
        );
      }
    }
  });

  client.once("ready", () => {
    console.log(`Logged in as ${client.user.tag}`);
  });

  client.on("error", (error) => {
    console.error(error.message);
  });

  client.login(DISCORD_TOKEN);
}

checkRobloxServer();
main();
