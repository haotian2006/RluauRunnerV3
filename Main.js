const {
  Client,
  GatewayIntentBits,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
  ActionRowBuilder,
  EmbedBuilder,
} = require("discord.js");
const { https } = require("follow-redirects");
const fs = require("fs");
const path = require("path");
const axios = require("axios");
const express = require("express");
const { console } = require("inspector");
const zstd = require("zstd-napi");
const { json } = require("stream/consumers");
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
const FORM_ID = process.env.FORM_ID;
const FORM_URL = `https://docs.google.com/forms/d/e/${FORM_ID}/formResponse`;

const SERVER_CREATION_COOL_DOWN = 1000 * 10;
const SERVER_RUN_TIME_MAX = 1000 * 60 * 1.5;
const SERVER_CHECK_INTERVAL = 1000;
const SERVER_PING_TIMEOUT = 1000 * 5;

const MAX_BYTECODE_LENGTH = 1024 * 20;

let IP = "";
let RunningServer = "";
let RunningServerTime = 0;
let LastServerPing = 0;

let LastServerCreation = 0;

const ExecuteTasks = {};
const CompilingTasks = {};
const Inputs = {};
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
        "entry.1569623480": name, //Make sure these entry ids are correct
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

function logBot(name, data) {
  log("0", "BOT", name, data);
}

https.get(LUAU_DOWNLOAD_URL, async (res) => {
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
      logBot("Luau Compiler", "Luau compiler loaded successfully.");
    });
  });
});

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function startRoblox() {
  let script = `require(workspace.LuauBot).start("${IP}") `;
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
    return false;
  }

  return true;
}

function getLinkFromData(data) {
  const channel_id = data.channelId;
  const msgID = data.targetId;
  return msgID ? `https://discord.com/channels/@me/${channel_id}/${msgID}` : "";
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
async function getCodeFromContextMenu(interaction,noCode) {
  let content = interaction.targetMessage.content;
  const attachments = interaction.targetMessage.attachments.first();

  // let codeBlocks = [...content.matchAll(/```(?:lua)?\s*([\s\S]*?)\s*```/g)].map(
  //   (m) => m[1]
  // );
  if (/```lua/.test(content)) {
    regex = /```lua\s*([\s\S]*?)\s*```/g;
  } else {
    regex = /```\w*\s*([\s\S]*?)\s*```/g;
  }
  let codeBlocks = [...content.matchAll(regex)].map(
    (m) => m[1].trim()
  );
  if (attachments && attachments.url) {
    content = await fetchFileContent(attachments.url);
    codeBlocks.unshift(content);
  }
  if (noCode) {
      return content;
  }
  if (codeBlocks.length === 0) {
    return content;
  }
  let code = codeBlocks[0];
  for (let i = 1; i < codeBlocks.length; i++) {
    let additionalCode = codeBlocks[i];
    if (additionalCode.includes("{CODE}")) {
      code = additionalCode.replace(/{CODE}/g, code);
    } else {
      code = code + "\n" + additionalCode;
    }
  }
  return code;
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

/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} data
 * @param {string} code
 */
async function createCompileModal(data, code) {
  const msgLink = `https://discord.com/channels/@me/${data.channelId}/${data.targetId}`;

  const modal = new ModalBuilder()
    .setCustomId("compile_modal")
    .setTitle("Generate Compile");

  const logInput = new TextInputBuilder()
    .setCustomId("log")
    .setLabel("Output Logs? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);
  
  const timestamps = new TextInputBuilder()
    .setCustomId("timestamps")
    .setLabel("Include Timestamps? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const runTime = new TextInputBuilder()
    .setCustomId("run_time")
    .setLabel("Max Run Time")
    .setStyle(TextInputStyle.Short)
    .setValue("15")
    .setRequired(true);

  const ephemeralInput = new TextInputBuilder()
    .setCustomId("ephemeral")
    .setLabel("Hide Result? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);

  const additionalCode = new TextInputBuilder()
    .setCustomId("additional_code")
    .setLabel("Additional Code (Optional)")
    .setStyle(TextInputStyle.Paragraph)
    .setValue(`--native\n--optimize 2\nlocal function run()\n\t{CODE}\nend\nlocal results = run()`)
    .setRequired(false);

  modal.addComponents(
    new ActionRowBuilder().addComponents(additionalCode),
    new ActionRowBuilder().addComponents(logInput),
    new ActionRowBuilder().addComponents(timestamps),
    new ActionRowBuilder().addComponents(runTime),
    new ActionRowBuilder().addComponents(ephemeralInput),
  );

  byteCodeModalData[data.user.id] = {
    data: data,
    content: code,
    msgLink: msgLink,
    data: data,
  };
  await data.showModal(modal);

  await wait(5 * 60 * 1000);
  delete byteCodeModalData[data.user.id];
}

async function sendCompileRequestToRoblox(
  code,
  interactionId,
  interactionToken,
  channelId,
  targetId,
  interaction,
  originalInteraction,
  isCommand = false
) {
  const uuid = generateUUID();
  ExecuteTasks[uuid] = {
    content: code,
    channelId: channelId,
    targetId: targetId,
    id: interactionId,
    token: interactionToken,
    userId: interaction.user.id,
    username: interaction.user.username,
    isCommand: isCommand,
  };
  CompilingTasks[interaction.token] = [interaction, originalInteraction];
  setTimeout(() => {
    delete ExecuteTasks[uuid];
  }, 1000 * 60 * 6);
}

async function reply(
  interaction,
  content,
  ephemeral = false,
  fileType = "lua",
  msgLink = null
) {
  try {
    const len = content.length;
    const link = msgLink || getLinkFromData(interaction);
    if (len > 1900) {
      await interaction.editReply({
        content:
          "Results For " + link + ":\nOutput too long sending as a file...",
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
        content:
          "Results For " +
          link +
          ":\n```" +
          `${fileType}\n` +
          content +
          "\n```",
        ephemeral: ephemeral,
      });
    }
  } catch (error) {
    console.error("Error in reply function:", error);
  }
}

function decodeBuffer(data) {
  if (data.zbase64) {
    return zstd
      .decompress(Buffer.from(data.zbase64, "base64"))
      .toString("utf-8");
  } else if (data.base64) {
    return Buffer.from(data.base64, "base64").toString("utf-8");
  }
}

app.patch("/respond", async (req, res) => {
  const token = req.body.token;
  try {
    let responseContent = decodeBuffer(JSON.parse(req.body.data));

    let logs = req.body.log;
    const [interaction, originalInteraction] = CompilingTasks[token];
    if (!interaction) {
      throw new Error("Interaction not found");
    }

    const link = getLinkFromData(originalInteraction || interaction);

    if (typeof logs === "string") {
      delete CompilingTasks[token];
    }

    const embed = new EmbedBuilder()
      .setTitle("Luau Compiler Results")
      .setDescription(
        `Requested by: <@${interaction.user.id}>` +
          `\`\`\`ansi\n${responseContent}\n\`\`\``
      )
      .addFields({
        name: "Remember To Follow the TOS",
        value: `<https://haotian2006.github.io/LuauBotSite/TOS/>`,
      })
      .setColor(3447003);

    if (link) {
      embed.setURL(link);
    }
    if (logs) {
      logs = decodeBuffer(JSON.parse(logs));

      await interaction.editReply({
        embeds: [embed],
        files: [
          {
            name: "logs.ansi",
            attachment: Buffer.from(logs, "utf-8"),
          },
        ],
      });
    } else {
      await interaction.editReply({ embeds: [embed] });
    }

    res.json({
      message: "Successfully sent response to Discord",
      data: "pass",
    });
  } catch (error) {
    delete CompilingTasks[token];
    console.error("Error handling /respond:", error);
    res.status(500).json({
      message: "Failed to send response to Discord",
      error: "failed",
    });
  }
});

app.get("/", (req, res) => {
  res.send("Bot is running!");
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

app.post("/getInputs", async (req, res) => {
  const interacted = req.body.i;

  data = [];

  for (const id in Inputs) {
    if (!(interacted.includes(Inputs[id].uid))) {
      data.push(Inputs[id]);
    }
  }
  res.json(data);
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
      logBot("Roblox Server", "Starting new Roblox server...");
      if (!(await startRoblox()) && hasTask) {
        Object.keys(ExecuteTasks).forEach((key) => {
          const task = ExecuteTasks[key];
          if (!task) return;
          if (!CompilingTasks || !CompilingTasks[task.token]) return;
          const [interaction, originalInteraction] = CompilingTasks[task.token];
          if (interaction) {
            try {
              interaction.editReply({
                content: `Failed to start Roblox server.`,
                ephemeral: true,
              });
            } catch (error) {}
            delete ExecuteTasks[key];
            delete CompilingTasks[task.token];
          }
        });
      }
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

async function main() {
  logBot("Luau Compiler", "Waiting");
  while (!luauModule || !luauModule.HEAPU8) {
    await wait(100);
  }

  console.log("Luau compiler is ready to use.");
  logBot("Luau Compiler", "Luau compiler is ready to use.");
  if (TUNNEL_URL) {
    IP = TUNNEL_URL;
  }
  logBot("Discord", "Registering interaction handler...");
  client.on("interactionCreate", async (interaction) => {
    try {
      if (interaction.isMessageContextMenuCommand()) {

         if (interaction.commandName === "input") {
          const code = await getCodeFromContextMenu(interaction,true);
          const uid = generateUUID();
          Inputs[uid] = {
            uid: uid,
            id: interaction.user.id,
            input: code,
          };
          interaction.reply({
            content: code.length > 100 ? `sent input (${code.length} characters)` : `sent '${code}'`,
            ephemeral: true,
          });

          log(
            interaction.user.id,
            interaction.user.username,
            interaction.commandName,
            `Input Length: ${code.length} characters`
          );
          wait(1000 * 30).then(() => {
            delete Inputs[uid];
          });
          return;
        }

        const code = await getCodeFromContextMenu(interaction);


        log(
          interaction.user.id,
          interaction.user.username,
          interaction.commandName,
          `Code length: ${code.length} characters`
        );
        // if (code.length > MAX_BYTECODE_LENGTH) {
        //   interaction.reply({
        //     content: `Code exceeds maximum length of ${
        //       MAX_BYTECODE_LENGTH / 1024
        //     } KB.`,
        //     ephemeral: true,
        //   });
        //   return;
        // }

        if (interaction.commandName === "bytecode") {
          await interaction.deferReply({ ephemeral: false });
          const options = getByteCodeOptions(code);
          const bytecode =
            byteCodeOptionsToString(options, code) + getByteCode(options, code);
          await reply(interaction, bytecode, false, "armasm");
        } else if (
          interaction.commandName === "bytecodeK" ||
          interaction.commandName === "decompile"
        ) {
          await interaction.deferReply({ ephemeral: false });
          const api =
            interaction.commandName === "bytecodeK"
              ? "disassemble"
              : "decompile";
          const options = getByteCodeOptions(code);
          options.remarks = false;
          options.binary = true;
          const bytecode = getByteCode(options, code);

          const bytecodeK = await kCall(api, bytecode);
          reply(
            interaction,
            byteCodeOptionsToString(options, code) + bytecodeK
          );
        } else if (interaction.commandName === "bytecodeWOption") {
          createByteModal(interaction, code);
        } else if (interaction.commandName === "compileWOption") {
          createCompileModal(interaction, code);
        } else if (interaction.commandName === "compile") {
          await interaction.deferReply({ ephemeral: false });
          // const options = getByteCodeOptions(code);
          // const bytecode = getByteCode(options, code);
          // if (
          //   bytecode &&
          //   bytecode.split("\n")[0].toLowerCase().includes("syntaxerror")
          // ) {
          //   interaction.editReply({ content: "```lua\n" + bytecode + "\n```" });
          //   return;
          // }
          sendCompileRequestToRoblox(
            code,
            interaction.id,
            interaction.token,
            interaction.channelId,
            interaction.targetId,
            interaction
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
          const useKonst =
            interaction.fields.getTextInputValue("konst") === "1";
          options.binary = useKonst;

          let bytecode = getByteCode(options, info.content);
          let type = "armasm";
          if (useKonst) {
            bytecode = await kCall("disassemble", bytecode);
            type = "lua";
          }
          await interaction.deferReply({ ephemeral: ephemeral });

          reply(
            interaction,
            byteCodeOptionsToString(options, info.content) + bytecode,
            ephemeral,
            type,
            info.msgLink
          );

          delete byteCodeModalData[interaction.user.id];
        } else if (interaction.customId === "compile_modal") {
          const info = byteCodeModalData[interaction.user.id];
          if (!info) return;
          const logOutput = interaction.fields.getTextInputValue("log") === "1";
          const timestamps =
            interaction.fields.getTextInputValue("timestamps") === "1";
          const runTime =
            interaction.fields.getTextInputValue("run_time") || "15";
          const ephemeral =
            interaction.fields.getTextInputValue("ephemeral") === "1";
          const additionalCode =
            interaction.fields.getTextInputValue("additional_code") || "";
          await interaction.deferReply({ ephemeral: ephemeral });

          let code = info.content;
          const originalInteraction = info.data;
          const headers = `OUTPUT_LOGS=${
            logOutput ? "true" : "false"
          }\nTIMESTAMP=${timestamps ? "true" : "false"}\nTIMEOUT=${runTime}\n`;
          if (additionalCode.includes("{CODE}")) {
            code = additionalCode.replace(/{CODE}/g, code);
          } else {
            code = code + "\n" + additionalCode;
          }
          code = headers + "\n" + code;

          delete byteCodeModalData[interaction.user.id];
          sendCompileRequestToRoblox(
            code,
            interaction.id,
            interaction.token,
            interaction.channelId,
            interaction.targetId,
            interaction,
            originalInteraction
          );
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
        } else if (interaction.commandName === "help") {
          await interaction.reply({
            content: `Check out the documentation at https://haotian2006.github.io/LuauBotSite/`,
          });
        } else if (
          interaction.commandName === "input" ||
          interaction.commandName === "hiddeninput"
        ) {
          const input = interaction.options.getString("input");
          const uid = generateUUID();
          Inputs[uid] = {
            uid: uid,
            id: interaction.user.id,
            input: input,
          };
          

          interaction.reply({
            content: `sent '${input}'`,
            ephemeral: interaction.commandName === "hiddeninput",
          });
          log(
            interaction.user.id,
            interaction.user.username,
            interaction.commandName,
            `Input Length: ${input.length} characters`
          );
          wait(1000 * 30).then(() => {
            delete Inputs[uid];
          });
        } else if (interaction.commandName === "compile") {
          await interaction.deferReply({ ephemeral: false });
          const code = interaction.options.getString("code");
          log(
            interaction.user.id,
            interaction.user.username,
            interaction.commandName,
            `Code length: ${code.length} characters`
          );

          // const options = getByteCodeOptions(code);
          // const bytecode = getByteCode(options, code);
          // if (
          //   bytecode &&
          //   bytecode.split("\n")[0].toLowerCase().includes("syntaxerror")
          // ) {
          //   interaction.editReply({ content: "```lua\n" + bytecode + "\n```" });
          //   return;
          // }
          sendCompileRequestToRoblox(
            code,
            interaction.id,
            interaction.token,
            interaction.channelId,
            interaction.targetId,
            interaction,
            null,
            true
          );
        }
      }
    } catch (error) {
      console.error("Error handling interaction:", error);
    }
  });

  client.once("ready", () => {
    console.log(`Logged in as ${client.user.tag}`);
    logBot("ready", `Logged in as ${client.user.tag}`);
  });

  client.on("error", (error) => {
    console.error(error.message);
    logBot("error", error.message);
  });
  logBot("Discord", "Logging in...\nToken Length: " + DISCORD_TOKEN?.length);
  client
    .login(DISCORD_TOKEN)
    .then(() => {
      logBot("Discord", "Logged in successfully.");
    })
    .catch((error) => {
      logBot("Discord", "Error logging in." + error);
      console.error("Error logging in:", error);
    });
}
logBot("Check Roblox Server", "Checking if Roblox server is online...");
checkRobloxServer();
logBot("Main", "Starting main bot process...");
main();
