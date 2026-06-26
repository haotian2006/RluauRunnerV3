const {
  Client,
  GatewayIntentBits,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
  ActionRowBuilder,
  EmbedBuilder,
  ButtonBuilder,
  ButtonStyle,
} = require("discord.js");
const { https } = require("follow-redirects");
const fs = require("fs");
const path = require("path");
const axios = require("axios");
const express = require("express");
const zstd = require("zstd-napi");

const os = require("os");
const { spawn } = require("child_process");

const {
  TextCensor,
  RegExpMatcher,
  englishDataset,
  englishRecommendedTransformers,
} = require("obscenity");
const { zstdCompress } = require("zlib");

const FILTER_BAD_WORDS = true;
require("dotenv").config();

function resolveExec(name) {
  const base = path.join(__dirname, name);
  if (process.platform === "win32") {
    const withExe = base + ".exe";
    if (fs.existsSync(withExe)) return withExe;
  }
  return base;
}

const PATH_TO_COMPILER = resolveExec("luau-compile");
const PATH_TO_ANALYZER = resolveExec("luau-analyze");
const PATH_TO_AST = resolveExec("luau-ast");
const PATH_TO_FORMATTER = resolveExec("stylua");
const DISCORD_TOKEN = process.env.BOT_TOKEN;
const DISCORD_APP_ID = process.env.CLIENT_ID;
const ROBLOX_API_KEY = process.env.ROBLOX_API_KEY;
const UNIVERSE_ID = process.env.UNIVERSE_ID;
const PLACE_ID = process.env.PLACE_ID;
const PORT = process.env.PORT || 3000;
const RESOURCES_URL =
  "https://api.github.com/repos/haotian2006/luau-runner-bot-resources/contents/resources?ref=main";
const KONST_API = "http://api.plusgiant5.com";
const EXECUTE_LUAU = `https://apis.roblox.com/cloud/v2/universes/${UNIVERSE_ID}/places/${PLACE_ID}/luau-execution-session-tasks`;
const TUNNEL_URL = process.env.TUNNEL_URL;
const FORM_ID = process.env.FORM_ID;
const FORM_URL = `https://docs.google.com/forms/d/e/${FORM_ID}/formResponse`;
const BACK_UP_EXECUTE_URL = process.env.BACK_UP_PATH || "";
const BACK_UP_KEY = process.env.BACK_UP_KEY || "";
const LUAU_MODULE = process.env.LUAU_MODULE || "";
const BACKUP_LUAU_MODULE = process.env.BACKUP_LUAU_MODULE || "";

const SERVER_CREATION_COOL_DOWN = 1000 * 20;
const SERVER_RUN_TIME_MAX = 1000 * 60 * 1.5; //This is how much before a new server is created regardless if old one is running
const SERVER_CHECK_INTERVAL = 1000;
const SERVER_PING_TIMEOUT = 1000 * 5;
const SERVER_TIME_OUT = "300s"; // this is how much before a server timeouts
const BACKUP_SERVER_WAIT_TIME = 1000 * 60 * 2;
const FILE_CHUNK_SIZE = 1024 * 1024 * 10; // 10 MB
const MAX_DATA_TO_SEND = 1024 * 1024 * 100; // 100 MB
const MAX_RESPONSE_FILES = 8;

let botSrcEncoded = fs.existsSync(path.join(__dirname, "luauBot.b64"))
  ? fs.readFileSync(path.join(__dirname, "luauBot.b64"), "utf-8")
  : "";

const SupportedFileTypes = new Set([
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "svg",
  "txt",
  "ansi",
  "lua",
  "luau",
  "json",
  "xml",
  "html",
  "css",
  "js",
  "md",
  "csv",
  "mp3",
  "wav",
  "ogg",
  "mp4",
  "webm",
  "rbxm",
]);

let IP = "";
const SECRET_TOKEN =
  Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
let RunningServer = "";
let RunningServerTime = 0;
let LastServerPing = 0;

let BackUpEndTime = 0;

let LastServerCreation = 0;

const Matcher = new RegExpMatcher({
  ...englishDataset.build(),
  ...englishRecommendedTransformers,
});
const Censor = new TextCensor();

function censorText(text) {
  if (!FILTER_BAD_WORDS) return text;
  const matches = Matcher.getAllMatches(text);
  return Censor.applyTo(text, matches);
}

const ExecuteTasks = {};
const CompilingTasks = {};
const Inputs = {};
const docCodeStore = {};
const app = express();
app.use(express.json());

function requireSecret(req, res, next) {
  if (req.headers["x-secret-token"] !== SECRET_TOKEN) {
    return res.status(403).json({ message: "Forbidden" });
  }
  next();
}
const client = new Client({
  intents: [GatewayIntentBits.Guilds],
});

// const luauFilePath = path.resolve("./LuauCompile.Web.js");
// let luauModule;

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
      },
    )
    .catch(() => {});
}

function logBot(name, data) {
  log("0", "BOT", name, data);
}

// https.get(LUAU_DOWNLOAD_URL, async (res) => {
//   if (res.statusCode !== 200) {
//     console.log(`Failed to get '${LUAU_DOWNLOAD_URL}' (${res.statusCode})`);
//     log("0", "BOT", "Failed to get Luau", res.statusCode);
//     luauModule = require(luauFilePath);
//     return;
//   }
//   const file = fs.createWriteStream(luauFilePath);
//   res.pipe(file);
//   file.on("finish", async () => {
//     file.close(async () => {
//       console.log("Luau downloaded successfully.");
//       const modulePath = path.resolve("./LuauCompile.Web.js");
//       luauModule = await import(`file://${modulePath}`);
//       luauModule = luauModule.default;
//       console.log("Luau compiler loaded successfully.");
//       logBot("Luau Compiler", "Luau compiler loaded successfully.");
//     });
//   });
// });

async function execute(executablePath, code, args) {
  return new Promise((resolve, reject) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-"));

    const inputPath = path.join(tmpDir, "Code.luau");
    const outputPath = path.join(tmpDir, "Output.luau");

    fs.writeFileSync(inputPath, code, "utf8");

    args.push(inputPath);

    const outputStream = fs.createWriteStream(outputPath);

    const child = spawn(executablePath, args);

    child.stdout.pipe(outputStream);
    child.stderr.pipe(outputStream);

    child.on("error", reject);

    child.on("close", (code) => {
      outputStream.end(() => {
        const output = fs.readFileSync(outputPath, "utf8");

        try {
          fs.unlinkSync(inputPath);
          fs.unlinkSync(outputPath);
          fs.rmdirSync(tmpDir);
        } catch {}

        resolve({ code, output });
      });
    });
  });
}

async function analyzeLuau(code, options) {
  const { annotate } = options;

  const args = [];
  if (annotate || true) {
    args.push("--annotate");
  }
  args.push("--fflags=LuauSolverV2=true");

  return await execute(PATH_TO_ANALYZER, code, args);
}

async function generateAST(code) {
  return await execute(PATH_TO_AST, code, []);
}

async function formatLuau(code) {
  return new Promise((resolve, reject) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-"));
    const inputPath = path.join(tmpDir, "Code.luau");
    fs.writeFileSync(inputPath, code, "utf8");

    let stderr = "";
    const child = spawn(PATH_TO_FORMATTER, ["--syntax=Luau", inputPath]);
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (exitCode) => {
      try {
        const output =
          exitCode !== 0 ? stderr : fs.readFileSync(inputPath, "utf8");
        try {
          fs.unlinkSync(inputPath);
          fs.rmdirSync(tmpDir);
        } catch {}
        resolve({ code: exitCode, output });
      } catch (err) {
        reject(err);
      }
    });
  });
}

async function compileLuau(code, options) {
  const {
    optimizeLevel,
    debugLevel,
    native,
    remarks,
    binary,
    architecture,
    constants,
  } = options;

  const args = [];

  if (native) {
    args.push("--codegen");
    args.push(`--target=${architecture}`);
  } else if (remarks) {
    args.push("--remarks");
  } else if (binary) {
    args.push("--binary");
  } else if (constants) {
    args.push("--dump-constants");
  }
  args.push(`-g${debugLevel}`);
  args.push(`-O${optimizeLevel}`);
  args.push("--vector-lib=Vector3");
  args.push("--vector-ctor=new");
  args.push("--vector-type=Vector3");

  return await execute(PATH_TO_COMPILER, code, args);
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isUserRestricted(interaction) {
  if (!interaction.inGuild()) return false;
  const member = interaction.member;
  if (!member) return false;
  if (typeof member.isCommunicationDisabled === "function") {
    if (member.isCommunicationDisabled()) return true;
  } else if (member.communication_disabled_until) {
    if (new Date(member.communication_disabled_until) > new Date()) return true;
  }
  const perms = interaction.memberPermissions;
  if (perms && !perms.has("SendMessages")) return true;
  return false;
}

function wrapEphemeral(interaction) {
  if (!isUserRestricted(interaction)) return;
  const origDefer = interaction.deferReply.bind(interaction);
  const origReply = interaction.reply.bind(interaction);
  interaction.deferReply = (opts = {}) =>
    origDefer({ ...opts, ephemeral: true });
  interaction.reply = (opts = {}) => {
    console.log("User is restricted, forcing ephemeral reply.");
    if (typeof opts === "string")
      return origReply({ content: opts, ephemeral: true });
    return origReply({ ...opts, ephemeral: true });
  };
}

let SERVERS_CREATED = 0;
async function startRoblox(
  path = EXECUTE_LUAU,
  key = ROBLOX_API_KEY,
  module = LUAU_MODULE,
) {
  let script = `require(${
    module !== "" ? module : "workspace.LuauBot"
  }).start("${IP}", "${SECRET_TOKEN}") `;
  if (botSrcEncoded) {
    script = `local EncodingService = game:GetService("EncodingService")

  local str = [[${botSrcEncoded}]]
  local decoded = EncodingService:Base64Decode(buffer.fromstring(str))
  decoded = EncodingService:DecompressBuffer(decoded,Enum.CompressionAlgorithm.Zstd)
  local Instances =  game:GetService("SerializationService"):DeserializeInstancesAsync(decoded)
  local module = Instances[1]
    
     require(module).start("${IP}", "${SECRET_TOKEN}")
`;
  }
  LastServerCreation = Date.now();
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": key,
    },
    body: JSON.stringify({
      script: script,
      timeout: SERVER_TIME_OUT,
    }),
  });
  if (!res.ok) {
    console.log("Failed to start Roblox: ", res.statusText);
    log("0", "BOT", "Failed to start Roblox", res.statusText);
    return false;
  }
  SERVERS_CREATED++;
  setTimeout(() => {
    SERVERS_CREATED--;
  }, 90000);
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
            new Error(
              `Failed to get data. Status Code: ${response.statusCode}`,
            ),
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

function fetchBinaryFile(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (response) => {
        if (response.statusCode !== 200) {
          reject(
            new Error(
              `Failed to get data. Status Code: ${response.statusCode}`,
            ),
          );
          return;
        }

        const chunks = [];

        response.on("data", (chunk) => {
          chunks.push(chunk);
        });

        response.on("end", () => {
          const buffer = Buffer.concat(chunks);
          resolve(buffer);
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

function getAnalysisOptions(code) {
  if (!code) {
    code = "";
  }
  const annotateMatch = code.match("--!annotate");

  return {
    annotate: !!annotateMatch,
  };
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
  const aMatch = code.match("--!architecture (\\S+)");
  let options = {
    architecture: aMatch ? aMatch[1] : "x64",
    native: code.indexOf("--!native") !== -1,
    binary: code.indexOf("--!binary") !== -1,
    remarks: code.indexOf("--!remarks") !== -1,
    constants: code.indexOf("--!dump-constants") !== -1,
    optimizeLevel: oMatch ? parseInt(oMatch[1]) : 2,
    debugLevel: dMatch ? parseInt(dMatch[1]) : 0,
  };
  if (options.native || options.remarks) {
    options.binary = false;
  }
  options.optimizeLevel = Math.max(0, Math.min(2, options.optimizeLevel));
  options.debugLevel = Math.max(0, Math.min(2, options.debugLevel));
  return options;
}

function byteCodeOptionsToString(options) {
  let str = "";
  if (options.remarks && !options.binary) {
    str += "Remarks: Enabled\n";
  }
  if (options.native) {
    str += "Native Codegen: Enabled\n";
    str += `Architecture: ${options.architecture}\n`;
  }
  str += `OptimizeLevel: ${options.optimizeLevel}\n`;
  str += `DebugLevel: ${options.debugLevel}\n`;
  str += "-------------------\n";
  return str;
}

async function getByteCode(options, code) {
  const result = await compileLuau(code, options);
  return result.output;
}

async function checkAndGetAttachmentText(attachment) {
  const validTextExtensions = [".txt", ".lua", ".luau", ".json"];
  const isTextFile = validTextExtensions.some((ext) =>
    attachment.name.toLowerCase().endsWith(ext),
  );

  if (!isTextFile) {
    return null;
  }
  return await fetchFileContent(attachment.url);
}

/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} interaction
 */
async function getInputsFromContext(interaction) {
  let content = interaction.targetMessage.content;
  const attachments = interaction.targetMessage.attachments;

  if (attachments.size === 0) {
    return [content];
  } else {
    const inputs = [];
    for (const attachment of attachments.values()) {
      const data = await fetchBinaryFile(attachment.url);
      inputs.push(data);
    }
    return inputs;
  }
}

/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} interaction
 */
async function getCodeFromContextMenu(interaction) {
  let content = interaction.targetMessage.content;
  const attachments = interaction.targetMessage.attachments.first();

  // let codeBlocks = [...content.matchAll(/```(?:lua)?\s*([\s\S]*?)\s*```/g)].map(
  //   (m) => m[1]
  // );
  // if (/```lua/.test(content)) {
  //   regex = /```lua\s*([\s\S]*?)\s*```/g;
  // } else {
  //   regex = /```\w*\s*([\s\S]*?)\s*```/g;
  // }
  regex = /```\w*\s*([\s\S]*?)\s*```/g;
  let codeBlocks = [...content.matchAll(regex)].map((m) => m[1].trim());
  if (attachments && attachments.url) {
    let data = await checkAndGetAttachmentText(attachments);

    if (data) {
      content = data;
      codeBlocks.unshift(content);
    }
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
  code = code.replace(
    /--\[==\[IGNORE START\]==\][\s\S]*?--\[==\[IGNORE END\]==\]/g,
    "",
  );
  return code;
}

const byteCodeModalData = {};
/**
 * @param {import('discord.js').MessageContextMenuCommandInteraction} data
 * @param {string} code
 */
async function createByteModal(data, code) {
  const msgLink = `https://discord.com/channels/@me/${data.channelId}/${data.targetId}`;

  const architectureInput = new TextInputBuilder()
    .setCustomId("architecture")
    .setLabel("Target Architecture(x64, a64, a64_nf, x64_ms)")
    .setStyle(TextInputStyle.Short)
    .setValue("")
    .setRequired(false);
  const native = new TextInputBuilder()
    .setCustomId("native")
    .setLabel("Use Native Codegen? (1 = yes, 0 = no)")
    .setStyle(TextInputStyle.Short)
    .setValue("0")
    .setRequired(false);
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
    // new ActionRowBuilder().addComponents(native),
    new ActionRowBuilder().addComponents(architectureInput),
    new ActionRowBuilder().addComponents(debugInput),
    // new ActionRowBuilder().addComponents(useKonst),
    new ActionRowBuilder().addComponents(remarksInput),
    new ActionRowBuilder().addComponents(ephemeralInput),
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
    .setValue(
      `--native\n--optimize 2\nlocal function run()\n\t{CODE}\nend\nlocal results = run()`,
    )
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

  setTimeout(
    () => {
      delete byteCodeModalData[data.user.id];
    },
    5 * 60 * 1000,
  );
  await data.showModal(modal);
}

function encodeZstd(input) {
  let buffer;

  if (Buffer.isBuffer(input)) {
    buffer = input;
  } else if (typeof input === "string") {
    buffer = Buffer.from(input, "utf-8");
  } else {
    logBot("Encode Zstd Error", "Input is not a string or Buffer");
    throw new TypeError("Input must be a string or Buffer");
  }

  const compressed = zstd.compress(buffer, 10);
  return compressed.toString("base64");
}
async function sendCompileRequestToRoblox(
  code,
  interactionId,
  interactionToken,
  channelId,
  targetId,
  interaction,
  originalInteraction,
  isCommand = false,
) {
  const uuid = generateUUID();
  ExecuteTasks[uuid] = {
    content: encodeZstd(code),
    channelId: channelId,
    targetId: targetId,
    id: interactionId,
    token: interactionToken,
    userId: interaction.user.id,
    username: interaction.user.username,
    isCommand: isCommand,
  };
  const timeoutId = setTimeout(
    () => {
      delete CompilingTasks[interaction.token];
      delete ExecuteTasks[uuid];
    },
    1000 * 60 * 6,
  );
  CompilingTasks[interaction.token] = [
    interaction,
    originalInteraction,
    null,
    0,
    null,
    timeoutId,
  ];
}

async function reply(
  interaction,
  content,
  ephemeral = false,
  fileType = "lua",
  msgLink = null,
) {
  try {
    const len = content.length;
    const link = msgLink || getLinkFromData(interaction);
    if (len > 1300) {
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
    return zstd.decompress(Buffer.from(data.zbase64, "base64"));
  } else if (data.base64) {
    return Buffer.from(data.base64, "base64");
  }
}

const CHUNK_TO_DATA = {};
let CHUNK_ID = 0;
function splitData(info) {
  if (info.checkedSplit) {
    return false;
  }
  // info will contain a `content` field that is a string
  const content = info.content;
  info.checkedSplit = true;
  const totalChunks = Math.ceil(content.length / FILE_CHUNK_SIZE);
  if (totalChunks <= 1) {
    return false;
  }

  if (content.length > MAX_DATA_TO_SEND) {
    info.content =
      "Data too large. Must be less than " + MAX_DATA_TO_SEND + " characters.";
    return false;
  }

  const chunks = [];
  for (let i = 0; i < totalChunks; i++) {
    const start = i * FILE_CHUNK_SIZE;
    const end = start + FILE_CHUNK_SIZE;
    const chunk = content.slice(start, end);
    const id = CHUNK_ID.toString();
    CHUNK_TO_DATA[id] = chunk;
    chunks.push(id);
    CHUNK_ID++;
  }
  info.content = chunks;
  setTimeout(() => {
    info.checkedSplit = false;
    info.content = content;
    for (const id of chunks) {
      delete CHUNK_TO_DATA[id];
    }
  }, 60 * 1000);
  return true;
}

/**
 * Retry a Discord operation with exponential backoff
 * @param {Function} operation - The async Discord operation to retry
 * @param {number} maxRetries - Maximum number of retry attempts
 * @param {string} operationName - Name of the operation for logging
 * @returns {Promise<any>} - Result of the operation
 */
async function retryDiscordOperation(
  operation,
  maxRetries = 3,
  operationName = "Discord operation",
) {
  let lastError;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      logBot(
        "Discord Retry",
        `${operationName} failed (attempt ${attempt}/${maxRetries}): ${error.message}`,
      );

      if (attempt < maxRetries) {
        const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
        await wait(delay);
      }
    }
  }
  throw lastError;
}

/**
 * Create embed with consistent formatting
 */
function createResponseEmbed(
  serverNum,
  userId,
  responseContent,
  isLast,
  runtime,
  msgLink,
) {
  const embed = new EmbedBuilder()
    .setTitle("Luau Compiler Results | Server #" + serverNum)
    .setDescription(
      (UsingBackup
        ? `[WARNING] Server creation quota reached. New sessions will be created less often. Frees <t:${BackUpEndTime}:R>. \n`
        : "") +
        `Requested by: <@${userId}>` +
        `\`\`\`ansi\n${censorText(responseContent) || " "}\n\`\`\``,
    )
    .setColor(UsingBackup ? 16488960 : 0x8ce4ff);

  if (isLast) {
    embed.setFooter({ text: `Compilation completed | ${runtime}s` });
    embed.setColor(UsingBackup ? 16488960 : 3447003);
  }

  if (msgLink) {
    embed.setURL(msgLink);
  }

  return embed;
}

/**
 * Handle follow-up response in Discord
 */
async function handleFollowUpResponse(
  interaction,
  embed,
  sentUrl,
  fileMap,
  dmMessage,
) {
  const followUpEmbed = new EmbedBuilder(embed.data)
    .setTitle("Follow up request")
    .setURL(sentUrl);

  const files =
    fileMap?.size > 0
      ? [...fileMap.values()].map(([l, ft, fn]) => ({
          name: `${fn}.${ft}`,
          attachment: l,
        }))
      : undefined;

  if (interaction.guild) {
    await retryDiscordOperation(
      () =>
        interaction.followUp({
          ephemeral: true,
          embeds: [followUpEmbed],
          ...(files && { files }),
        }),
      3,
      "Follow-up in guild",
    );
  } else {
    try {
      followUpEmbed.addFields(
        {
          name: "Info",
          value:
            "This is a follow up request. You can still use `/input` to send inputs to the bot. The purpose of this is allow you to send inputs without having to scroll up to find the changes. This will also update the main interaction message.",
          inline: false,
        },
        {
          name: "Tip",
          value: "Use `/hiddeninput` to not flood dms with inputs",
          inline: true,
        },
      );

      if (dmMessage) {
        await retryDiscordOperation(
          () =>
            dmMessage.edit({
              embeds: [followUpEmbed],
              ...(files && { files }),
            }),
          3,
          "Edit DM message",
        );
      } else {
        const newDmMessage = await retryDiscordOperation(
          () =>
            interaction.user.send({
              embeds: [followUpEmbed],
              ...(files && { files }),
            }),
          3,
          "Send DM",
        );

        await interaction.followUp({
          content:
            "A new DM has been sent to you with the follow up response. " +
            newDmMessage.url,
          ephemeral: true,
        });

        return newDmMessage;
      }
    } catch (err) {
      logBot("Follow-up Error", `Failed to send DM follow-up: ${err.message}`);
    }
  }
  return null;
}

/**
 * Retrieve chunked logs with timeout
 */
async function retrieveChunkedLogs(respondID, numSections, interaction, link) {
  logBot(
    "Respond Endpoint",
    `Retrieving chunked logs sections: ${numSections} from: ${interaction.user.id} link: ${link}`,
  );

  const startTime = Date.now();
  const timeout = 60 * 1000;

  while (Date.now() - startTime < timeout) {
    const chunkedLogs = RecvChunks[respondID];
    if (chunkedLogs && chunkedLogs.length >= numSections) {
      chunkedLogs.sort((a, b) => a.index - b.index);
      const concatenated = chunkedLogs.map((chunk) => chunk.data).join("");
      delete RecvChunks[respondID];
      return { success: true, data: decodeBuffer(JSON.parse(concatenated)) };
    }
    await wait(500);
  }

  const chunkedLogs = RecvChunks[respondID];
  delete RecvChunks[respondID];

  return {
    success: false,
    data: chunkedLogs
      ? Buffer.from(
          `Failed to retrieve logs (received ${chunkedLogs.length}/${numSections} sections)`,
          "utf-8",
        )
      : Buffer.from("Failed to retrieve logs", "utf-8"),
    fileName: "failed_to_retrieve_logs",
    fileType: "txt",
  };
}

let UsingBackup = false;
const RecvChunks = {};
app.patch("/uploadChunk", requireSecret, async (req, res) => {
  const chunk = req.body.chunk;
  const fileChunksId = req.body.token;
  const index = req.body.index;
  if (!RecvChunks[fileChunksId]) {
    RecvChunks[fileChunksId] = [];
    setTimeout(() => {
      delete RecvChunks[fileChunksId];
    }, 80000);
  }
  RecvChunks[fileChunksId].push({ index: index, data: chunk });
  res.status(200).json({ message: "Chunk received" });
});

app.patch("/respond", requireSecret, async (req, res) => {
  const token = req.body.token;
  const serverNum = req.body.serverNum;
  let _interaction;
  let _link;

  try {
    const responseContent = decodeBuffer(JSON.parse(req.body.data)).toString(
      "utf-8",
    );
    const isLast = req.body.finished;
    const followUp = req.body.followUp;
    const runtime = req.body.runtime || 0;
    const numSections = req.body.sections;
    const respondID = req.body.fileId;

    let fileType = req.body.fileType;
    let fileName;
    if (fileType && fileType.includes(".")) {
      [fileName, fileType] = fileType.split(".");
    }
    fileType =
      fileType && SupportedFileTypes.has(fileType.toLowerCase())
        ? fileType.toLowerCase()
        : "ansi";
    fileName = fileName || "output";

    if (!CompilingTasks[token]) {
      return res.status(500).json({
        message: "Failed to send response to Discord",
        error: "Invalid or expired token",
      });
    }

    const [
      interaction,
      originalInteraction,
      fileMap,
      prevResponseId = 0,
      dmMessage = null,
    ] = CompilingTasks[token];

    _interaction = interaction;
    const link = getLinkFromData(originalInteraction || interaction);
    _link = link;

    let logs = req.body.log;

    if (logs) {
      if (numSections) {
        const result = await retrieveChunkedLogs(
          respondID,
          numSections,
          interaction,
          link,
        );
        logs = result.data;
        if (!result.success) {
          fileName = result.fileName;
          fileType = result.fileType;
        }
      } else {
        logs = decodeBuffer(JSON.parse(logs));
      }
    }

    const isNewResponse = respondID > prevResponseId;
    if (isNewResponse && CompilingTasks[token]) {
      CompilingTasks[token][3] = respondID;
    }

    if (logs && CompilingTasks[token] && isNewResponse) {
      if (!CompilingTasks[token][2]) {
        CompilingTasks[token][2] = new Map();
      }
      const map = CompilingTasks[token][2];
      if (map.size >= MAX_RESPONSE_FILES) {
        map.delete(map.keys().next().value);
      }
      map.set(`${fileName}.${fileType}`, [logs, fileType, fileName]);
    }

    const currentFileMap = CompilingTasks[token]?.[2] ?? fileMap;

    if (isLast) {
      clearTimeout(CompilingTasks[token]?.[5]);
      delete CompilingTasks[token];
    }

    const embed = createResponseEmbed(
      serverNum,
      interaction.user.id,
      responseContent,
      isLast,
      runtime,
      link,
    );

    if (isNewResponse) {
      const files =
        currentFileMap?.size > 0
          ? [...currentFileMap.values()].map(([l, ft, fn]) => ({
              name: `${fn}.${ft}`,
              attachment: l,
            }))
          : undefined;

      const replyOptions = {
        embeds: [embed],
        ...(files && { files }),
      };

      const sent = await retryDiscordOperation(
        () => interaction.editReply(replyOptions),
        3,
        "Edit reply",
      );

      if (followUp || dmMessage) {
        const newDmMessage = await handleFollowUpResponse(
          interaction,
          embed,
          sent.url,
          currentFileMap,
          dmMessage,
        );

        if (newDmMessage && CompilingTasks[token]) {
          CompilingTasks[token][4] = newDmMessage;
        }
      }
    }

    res.json({
      message: "Successfully sent response to Discord",
      data: "pass",
    });
  } catch (error) {
    logBot("Respond Endpoint Error", `${error.message} stack: ${error.stack}`);

    if (_interaction) {
      try {
        const errorEmbed = new EmbedBuilder()
          .setTitle("Discord Error")
          .setDescription(
            `Requested by: <@${_interaction.user.id}>\nERROR: ${error.message}`,
          )
          .setColor(0xff0000);

        if (_link) {
          errorEmbed.setURL(_link);
        }

        await retryDiscordOperation(
          () => _interaction.editReply({ embeds: [errorEmbed] }),
          2,
          "Error reply",
        );
      } catch (editError) {
        logBot(
          "Error Reply Failed",
          `Failed to edit reply with error: ${editError.message}`,
        );
      }
    }

    clearTimeout(CompilingTasks[token]?.[5]);
    delete CompilingTasks[token];
    res.status(500).json({
      message: "Failed to send response to Discord",
      error: error.message,
    });
  }
});

app.post("/debug", requireSecret, async (req, res) => {
  const message = req.body.message;
  console.log("Debug Message:", message);
  logBot("Debug Endpoint", message);
  res.status(200).json({ message: "Debug message logged" });
});

app.post("/chunk", requireSecret, async (req, res) => {
  const chunkId = req.body.id;
  if (chunkId in CHUNK_TO_DATA) {
    res.status(200).json({ chunk: CHUNK_TO_DATA[chunkId] });
  } else {
    res.status(404).json({ message: "Chunk not found" });
  }
});

app.get("/", (req, res) => {
  res.send("Bot is running!");
});
let SERVER_NUMBERS = 0;
app.post("/start", requireSecret, async (req, res) => {
  RunningServer = req.body.ServerId;
  RunningServerTime = Date.now();
  SERVER_NUMBERS += 1;
  res.json({ message: "Server started", id: SERVER_NUMBERS % 256 });
});

app.post("/ping", requireSecret, (req, res) => {
  if (req.body.ServerId === RunningServer) {
    LastServerPing = Date.now();
  }
  res.json({ message: "Ping received" });
});

app.post("/getInputs", requireSecret, async (req, res) => {
  const interacted = req.body.i;

  data = [];
  for (const id in Inputs) {
    if (!interacted.includes(Inputs[id].uid)) {
      if (!Inputs[id].encoded) {
        Inputs[id].content = encodeZstd(Inputs[id].input);
        Inputs[id].encoded = true;
        delete Inputs[id].input;
      }

      splitData(Inputs[id]);

      data.push(Inputs[id]);
    }
  }
  res.json(data);
});

app.post("/getAll", requireSecret, async (req, res) => {
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

app.post("/get", requireSecret, async (req, res) => {
  const TaskId = req.body.TaskId;
  if (TaskId in ExecuteTasks) {
    splitData(ExecuteTasks[TaskId]);
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
    let debounce =
      SERVERS_CREATED <= 2
        ? SERVER_CREATION_COOL_DOWN / 1.5
        : SERVERS_CREATED >= 5
          ? SERVER_CREATION_COOL_DOWN * 1.5
          : SERVER_CREATION_COOL_DOWN;
    if (UsingBackup) {
      debounce = SERVER_CREATION_COOL_DOWN * 2;
    }
    const lastCreationDebounce = Date.now() - LastServerCreation > debounce;
    if (hasTask && (serverTimeout || pingTimeout) && lastCreationDebounce) {
      console.log("Starting new Roblox server...");
      logBot("Roblox Server", "Starting new Roblox server...");

      let started = UsingBackup ? false : await startRoblox();
      if (!started && BACK_UP_EXECUTE_URL !== "") {
        if (!UsingBackup) {
          BackUpEndTime = Math.floor(
            (Date.now() + BACKUP_SERVER_WAIT_TIME) / 1000,
          );
          setTimeout(() => {
            UsingBackup = false;
          }, BACKUP_SERVER_WAIT_TIME);
        }
        UsingBackup = true;
        logBot(
          "Roblox Server",
          "Failed to start primary Roblox server, attempting backup...",
        );
        started = await startRoblox(
          BACK_UP_EXECUTE_URL,
          BACK_UP_KEY,
          BACKUP_LUAU_MODULE,
        );
      }
      if (!started) {
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
            clearTimeout(CompilingTasks[task.token]?.[5]);
            delete CompilingTasks[task.token];
          }
        });
      }
    }
    await wait(SERVER_CHECK_INTERVAL);
  }
}

function stripNoShowForExecution(code) {
  return code
    .replace(/--\[\[NO_SHOW\]\]\r?\n?/g, "")
    .replace(/--\[\[END\]\]\r?\n?/g, "");
}

function stripNoShowForDisplay(text) {
  return text
    .replace(/--\[\[NO_SHOW\]\][\s\S]*?--\[\[END\]\]/g, "")
    .replace(/--\[\[NO_EXECUTE\]\]\r?\n?/g, "")
    .replace(/--\[\[name:[^\]]*\]\]\r?\n?/g, "");
}

function extractDocCodeBlocks(markdown) {
  const results = [];
  const fence = /```(?:lua|luau)[^\n]*\n([\s\S]*?)```/g;
  let match;
  while ((match = fence.exec(markdown)) !== null) {
    let raw = match[1].trim();
    if (!raw) continue;
    if (raw.includes("--[[NO_EXECUTE]]")) continue;
    let label = "";
    let codeBody = raw;
    const nameMatch = raw.match(/^--\[\[name:\s*(.+?)\]\]/);
    if (nameMatch) {
      label = nameMatch[1].trim();
      raw = raw.slice(raw.indexOf("\n") + 1).trim();
    } else {
      const before = markdown.slice(0, match.index);
      const lines = before.split("\n").map((l) => l.trim());
      for (let i = lines.length - 1; i >= 0; i--) {
        if (/^#+\s/.test(lines[i])) {
          label = lines[i];
          break;
        }
      }
      if (!label) {
        const nonEmpty = lines.filter((l) => l.length > 0);
        label = nonEmpty[nonEmpty.length - 1] || `Block ${results.length + 1}`;
      }
      label = label
        .replace(/^#+\s*/, "")
        .replace(/\*\*/g, "")
        .replace(/\*/g, "")
        .trim();
      label = label.split(" - ")[0].trim();
    }
    if (label.length > 80) label = label.slice(0, 77) + "...";
    const code = stripNoShowForExecution(raw);
    results.push({ code, label });
  }
  return results;
}

async function main() {
  // logBot("Luau Compiler", "Waiting");
  // while (!luauModule || !luauModule.HEAPU8) {
  //   await wait(100);
  // }

  // console.log("Luau compiler is ready to use.");
  // logBot("Luau Compiler", "Luau compiler is ready to use.");
  if (TUNNEL_URL) {
    IP = TUNNEL_URL;
  }
  console.log("Bot is starting...");
  logBot("Discord", "Registering interaction handler...");
  let resourcesCache = null;
  let resourcesCacheTime = 0;

  async function getResources() {
    if (resourcesCache && Date.now() - resourcesCacheTime < 1000 * 60 * 5) {
      return resourcesCache;
    }
    const res = await axios.get(RESOURCES_URL, {
      headers: { "User-Agent": "luau-runner-bot" },
    });
    resourcesCache = res.data.filter((f) => f.type === "file");
    resourcesCacheTime = Date.now();
    return resourcesCache;
  }

  function resourceDisplayName(filename) {
    return filename.replace(/\.md$/i, "").replace(/-/g, " ");
  }

  client.on("interactionCreate", async (interaction) => {
    try {
      wrapEphemeral(interaction);

      if (
        interaction.isButton() &&
        interaction.customId.startsWith("tag_run:")
      ) {
        const uuid = interaction.customId.slice("tag_run:".length);
        const code = docCodeStore[uuid];
        if (!code) {
          await interaction.reply({
            content: "This button has expired.",
            ephemeral: true,
          });
          return;
        }
        await interaction.deferReply({ ephemeral: false });
        sendCompileRequestToRoblox(
          code,
          interaction.id,
          interaction.token,
          interaction.channelId,
          null,
          interaction,
          null,
          false,
        );
        return;
      }

      if (interaction.isAutocomplete()) {
        if (interaction.commandName === "tag") {
          const focused = interaction.options.getFocused().toLowerCase();
          try {
            const files = await getResources();
            const choices = files
              .filter((f) =>
                resourceDisplayName(f.name).toLowerCase().includes(focused),
              )
              .slice(0, 25)
              .map((f) => ({
                name: resourceDisplayName(f.name),
                value: f.name,
              }));
            await interaction.respond(choices);
          } catch (e) {
            await interaction.respond([]);
          }
        }
        return;
      }

      if (interaction.isMessageContextMenuCommand()) {
        if (interaction.commandName === "input") {
          const inputs = await getInputsFromContext(interaction);
          for (const input of inputs) {
            try {
              const eSize = encodeZstd(input).length;

              if (eSize > MAX_DATA_TO_SEND) {
                interaction.reply({
                  content: `Input exceeds maximum size of ${Math.floor(
                    MAX_DATA_TO_SEND / 1024,
                  )} KB after compression (current size: ${Math.floor(
                    eSize / 1024,
                  )} KB).`,
                  ephemeral: true,
                });

                return;
              }

              const uid = generateUUID();
              Inputs[uid] = {
                uid: uid,
                id: interaction.user.id,
                input: input,
              };

              log(
                interaction.user.id,
                interaction.user.username,
                interaction.commandName,
                `Input Length: ${input.length} characters`,
              );
              setTimeout(() => {
                delete Inputs[uid];
              }, 1000 * 30);
            } catch (err) {
              logBot("Input Error", `Error processing input: ${err.message}`);
            }
          }
          interaction.reply({
            content: "Sent " + inputs.length + " Input(s)",
          });

          return;
        }

        const code = await getCodeFromContextMenu(interaction);

        log(
          interaction.user.id,
          interaction.user.username,
          interaction.commandName,
          `Code length: ${code.length} characters`,
        );
        console.log(
          `User ${interaction.user.username} (${interaction.user.id}) invoked ${interaction.commandName} with code length: ${code.length} characters`,
        );

        if (interaction.commandName === "bytecode") {
          await interaction.deferReply({ ephemeral: false });
          console.log("Generating bytecode with options...");
          const options = getByteCodeOptions(code);
          const bytecode =
            byteCodeOptionsToString(options, code) +
            (await getByteCode(options, code));
          await reply(interaction, bytecode, false, "armasm");
        } else if (interaction.commandName === "analyze") {
          await interaction.deferReply({ ephemeral: false });
          const options = getAnalysisOptions(code);

          const analysis = await analyzeLuau(
            code.replace("--!annotate", ""),
            options,
          );
          await reply(interaction, analysis.output, false, "lua");
        } else if (interaction.commandName === "ast") {
          await interaction.deferReply({ ephemeral: false });
          const ast = await generateAST(code);
          await reply(interaction, ast.output, false, "json");
        } else if (interaction.commandName === "format") {
          await interaction.deferReply({ ephemeral: false });
          const result = await formatLuau(code);
          let formattedCode = result.output || "";
          if (formattedCode.match("error: could not format file")) {
            formattedCode = code;
          }
          await reply(interaction, formattedCode, false, "lua");
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
          const bytecode = await getByteCode(options, code);

          const bytecodeK = await kCall(api, bytecode);
          reply(
            interaction,
            byteCodeOptionsToString(options, code) + bytecodeK,
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
            interaction,
          );
        }
      } else if (interaction.isModalSubmit()) {
        if (interaction.customId === "bytecode_modal") {
          const info = byteCodeModalData[interaction.user.id];
          if (!info) return;
          const options = getByteCodeOptions();
          options.architecture =
            interaction.fields.getTextInputValue("architecture") || "";
          options.remarks =
            interaction.fields.getTextInputValue("remarks") === "1";
          options.optimizeLevel =
            parseInt(
              interaction.fields.getTextInputValue("optimize_level"),
              10,
            ) || 0;
          options.debugLevel =
            parseInt(interaction.fields.getTextInputValue("debug_level"), 10) ||
            0;

          options.native = options.architecture !== "";
          // interaction.fields.getTextInputValue("native") === "1";

          const ephemeral =
            interaction.fields.getTextInputValue("ephemeral") === "1";
          // const useKonst =
          //   interaction.fields.getTextInputValue("konst") === "1";
          // options.binary = useKonst;
          info.content = info.content
            .replace("--!optimize", "--")
            .replace("--!native", "--aaa");
          let bytecode = await getByteCode(options, info.content);
          let type = "armasm";
          // if (useKonst) {
          //   bytecode = await kCall("disassemble", bytecode);
          //   type = "lua";
          // }
          await interaction.deferReply({ ephemeral: ephemeral });

          reply(
            interaction,
            byteCodeOptionsToString(options, info.content) + bytecode,
            ephemeral,
            type,
            info.msgLink,
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
          const headers = `\nOUTPUT_LOGS=${
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
            originalInteraction,
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
            `Pong! ${diff}ms.`,
          );
          await interaction.editReply(`Pong! ${diff}ms.`);
        } else if (interaction.commandName === "help") {
          await interaction.reply({
            content: `Check out the documentation at https://haotian2006.github.io/LuauBotSite/`,
          });
        } else if (
          interaction.commandName === "input" ||
          interaction.commandName === "hiddeninput" ||
          interaction.commandName === "stopall"
        ) {
          const isStop = interaction.commandName === "stopall";
          const input = isStop
            ? "STOP_ALL_SESSIONS_PLS"
            : interaction.options.getString("input") || "";
          const uid = generateUUID();
          Inputs[uid] = {
            uid: uid,
            id: interaction.user.id,
            input: input,
          };

          interaction.reply({
            content: `sent '${isStop ? "a stop command" : censorText(input)}'`,
            ephemeral:
              interaction.commandName === "hiddeninput" ||
              interaction.commandName === "stopall",
          });
          if (interaction.commandName === "hiddeninput") {
            setTimeout(() => {
              interaction.deleteReply();
            }, 3000);
          }

          log(
            interaction.user.id,
            interaction.user.username,
            interaction.commandName,
            `Input Length: ${input.length} characters`,
          );

          if (isStop) {
            try {
              const userId = interaction.user.id;
              let removed = 0;
              for (const token in CompilingTasks) {
                const entry = CompilingTasks[token];
                if (!entry || !entry[0] || !entry[0].user) continue;
                if (entry[0].user.id === userId) {
                  clearTimeout(entry[5]);
                  delete CompilingTasks[token];
                  removed++;
                  for (const taskId in ExecuteTasks) {
                    if (
                      ExecuteTasks[taskId] &&
                      ExecuteTasks[taskId].token === token
                    ) {
                      delete ExecuteTasks[taskId];
                    }
                  }
                }
              }
              log(
                interaction.user.id,
                interaction.user.username,
                interaction.commandName,
                `Stopped ${removed} session(s)`,
              );
            } catch (err) {
              console.error("Error stopping sessions:", err);
            }
          }
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
            `Code length: ${code.length} characters`,
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
            true,
          );
        } else if (interaction.commandName === "tag") {
          await interaction.deferReply({ ephemeral: false });
          const resourceName = interaction.options.getString("resource");
          const target = interaction.options.getUser("target");
          log(
            interaction.user.id,
            interaction.user.username,
            interaction.commandName,
            `Tag: ${resourceName}`,
          );
          try {
            const files = await getResources();
            const file = files.find((f) => f.name === resourceName);
            if (!file) {
              await interaction.editReply({
                content: `Resource \`${resourceName}\` not found.`,
              });
              return;
            }
            const contentRes = await axios.get(file.download_url);
            const text = contentRes.data;
            const displayName = resourceDisplayName(file.name);
            const displayText = stripNoShowForDisplay(text);
            const embed = new EmbedBuilder()
              .setTitle(displayName)
              .setDescription(
                displayText.length > 4096
                  ? displayText.substring(0, 4093) + "..."
                  : displayText,
              )
              .setURL(file.html_url)
              .setColor(0x5865f2);
            const mention = target ? `<@${target.id}> ` : "";

            const codeBlocks = extractDocCodeBlocks(text);
            const components = [];
            if (codeBlocks.length > 0) {
              const uuids = codeBlocks.map((block) => {
                const uuid = generateUUID();
                docCodeStore[uuid] =
                  `log("Running: ${block.label}", "cyan", true)\n${block.code}`;
                setTimeout(
                  () => {
                    delete docCodeStore[uuid];
                  },
                  1000 * 60 * 10,
                );
                return uuid;
              });
              for (let i = 0; i < Math.min(codeBlocks.length, 25); i += 5) {
                const row = new ActionRowBuilder();
                const slice = codeBlocks.slice(i, i + 5);
                row.addComponents(
                  slice.map((block, j) =>
                    new ButtonBuilder()
                      .setCustomId(`tag_run:${uuids[i + j]}`)
                      .setLabel(block.label)
                      .setStyle(ButtonStyle.Primary),
                  ),
                );
                components.push(row);
              }
            }

            await interaction.editReply({
              content: mention || undefined,
              embeds: [embed],
              components,
              allowedMentions: { users: target ? [target.id] : [] },
            });
          } catch (e) {
            await interaction.editReply({
              content: `Failed to fetch resource: ${e.message}`,
            });
          }
        }
      }
    } catch (error) {
      console.error("Error handling interaction:", error);
      logBot(
        "Interaction Error",
        `Error handling interaction: ${error.message}`,
      );
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
