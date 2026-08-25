const { EmbedBuilder } = require("discord.js");

const { MAX_RESPONSE_FILES, SupportedFileTypes } = require("../../config");
const { decodeBuffer } = require("../../chunks");
const { logBot } = require("../../log");
const { CompilingTasks, settleTasksForToken } = require("../../state");
const {
  createResponseEmbed,
  handleFollowUpResponse,
  liveAttachmentOptions,
} = require("../../discord/embeds");
const { cleanupScriptButtons } = require("../../discord/scriptButtons");
const {
  getLinkFromData,
  retryDiscordOperation,
} = require("../../discord/reply");
const {
  ChunkRejected,
  MAX_SECTIONS,
  addChunk,
  waitForUpload,
} = require("../chunkIntake");
const { requireSecret } = require("../middleware");

const SAFE_NAME = /[^A-Za-z0-9_-]/g;
const MAX_NAME_LENGTH = 64;

function sanitizeFileName(name) {
  if (typeof name !== "string") return "output";
  const cleaned = name.replace(SAFE_NAME, "").slice(0, MAX_NAME_LENGTH);
  return cleaned || "output";
}

function parseFileType(raw) {
  let fileType = raw;
  let fileName;
  if (typeof fileType === "string" && fileType.includes(".")) {
    [fileName, fileType] = fileType.split(".");
  }
  fileType =
    typeof fileType === "string" &&
    SupportedFileTypes.has(fileType.toLowerCase())
      ? fileType.toLowerCase()
      : "ansi";
  return { fileName: sanitizeFileName(fileName), fileType };
}

async function retrieveChunkedLogs(respondID, numSections, interaction, link) {
  logBot(
    "Respond Endpoint",
    `Retrieving chunked logs sections: ${numSections} from: ${interaction.user.id} link: ${link}`,
  );

  const result = await waitForUpload(respondID, numSections);

  if (result.success) {
    try {
      return { success: true, data: decodeBuffer(JSON.parse(result.data)) };
    } catch (err) {
      logBot(
        "Respond Endpoint",
        `Failed to decode reassembled logs: ${err.message}`,
      );
      return {
        success: false,
        data: Buffer.from(`Failed to decode logs: ${err.message}`, "utf-8"),
        fileName: "failed_to_retrieve_logs",
        fileType: "txt",
      };
    }
  }

  return {
    success: false,
    data: Buffer.from(
      `Failed to retrieve logs (received ${result.received}/${numSections} sections)`,
      "utf-8",
    ),
    fileName: "failed_to_retrieve_logs",
    fileType: "txt",
  };
}

function registerRespondRoutes(app) {
  app.patch("/uploadChunk", requireSecret, async (req, res) => {
    try {
      addChunk(req.body.token, req.body.index, req.body.chunk);
      res.status(200).json({ message: "Chunk received" });
    } catch (error) {
      if (error instanceof ChunkRejected) {
        logBot("Upload Chunk Rejected", error.message);
        return res.status(400).json({ message: error.message });
      }
      throw error;
    }
  });

  app.patch("/respond", requireSecret, async (req, res) => {
    const token = req.body.token;
    const serverNum = req.body.serverNum;
    let _interaction;
    let _link;

    try {
      if (typeof req.body.data !== "string") {
        return res
          .status(400)
          .json({ message: "data must be a JSON-encoded string" });
      }

      const responseContent = decodeBuffer(JSON.parse(req.body.data)).toString(
        "utf-8",
      );
      const isLast = req.body.finished;
      const followUp = req.body.followUp;
      const runtime = req.body.runtime || 0;
      const numSections = req.body.sections;
      const respondID = req.body.fileId;

      let { fileName, fileType } = parseFileType(req.body.fileType);

      if (!CompilingTasks[token]) {
        return res.status(500).json({
          message: "Failed to send response to Discord",
          error: "Invalid or expired token",
        });
      }

      settleTasksForToken(token);

      const [
        interaction,
        originalInteraction,
        fileMap,
        prevResponseId = 0,
        dmMessage = null,
        timeoutId,
        attachmentMap = new Map(),
        buttonMap = new Map(),
      ] = CompilingTasks[token];

      _interaction = interaction;
      const link = getLinkFromData(originalInteraction || interaction);
      _link = link;

      let logs = req.body.log;

      if (logs) {
        if (numSections) {
          if (!Number.isInteger(numSections) || numSections > MAX_SECTIONS) {
            return res
              .status(400)
              .json({
                message: `sections must be an integer <= ${MAX_SECTIONS}`,
              });
          }
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
        const key = `${fileName}.${fileType}`;
        if (!map.has(key) && map.size >= MAX_RESPONSE_FILES) {
          map.delete(map.keys().next().value);
        }
        map.set(key, [logs, fileType, fileName]);
      }

      const currentFileMap = CompilingTasks[token]?.[2] ?? fileMap;
      const changedFileName =
        logs && isNewResponse ? `${fileName}.${fileType}` : null;

      if (isLast) {
        clearTimeout(timeoutId);
        cleanupScriptButtons(buttonMap);
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
        const replyOptions = {
          embeds: [embed],
          ...(isLast && { components: [] }),
        };

        if (changedFileName) {
          Object.assign(
            replyOptions,
            liveAttachmentOptions(attachmentMap.values(), currentFileMap, {
              name: changedFileName,
              attachment: logs,
            }),
          );
        }

        const sent = await retryDiscordOperation(
          () => interaction.editReply(replyOptions),
          3,
          "Edit reply",
        );

        if (changedFileName && CompilingTasks[token]) {
          CompilingTasks[token][6] = new Map(
            [...sent.attachments.values()].map((attachment) => [
              attachment.name,
              attachment,
            ]),
          );
        }

        if (followUp || dmMessage) {
          const newDmMessage = await handleFollowUpResponse(
            interaction,
            embed,
            sent.url,
            currentFileMap,
            dmMessage,
            changedFileName
              ? { name: changedFileName, attachment: logs }
              : undefined,
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
      logBot(
        "Respond Endpoint Error",
        `${error.message} stack: ${error.stack}`,
      );

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
            () =>
              _interaction.editReply({
                embeds: [errorEmbed],
                components: [],
              }),
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
      cleanupScriptButtons(CompilingTasks[token]?.[7]);
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
}

module.exports = { registerRespondRoutes };
