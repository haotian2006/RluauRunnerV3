const { MAX_RESPONSE_FILES, SupportedFileTypes } = require("../../config");
const { decodeBuffer } = require("../../chunks");
const { logBot } = require("../../log");
const { settleTasksForToken } = require("../../state");
const { closeSession, getSession } = require("../../core/sessions");
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

async function retrieveChunkedLogs(respondID, numSections, token) {
  logBot(
    "Respond Endpoint",
    `Retrieving chunked logs sections: ${numSections} for token: ${token}`,
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

// Evicts the oldest once the response carries as many as Discord will take.
function recordFile(session, fileName, fileType, logs) {
  if (!session.fileMap) {
    session.fileMap = new Map();
  }
  const key = `${fileName}.${fileType}`;
  if (!session.fileMap.has(key) && session.fileMap.size >= MAX_RESPONSE_FILES) {
    session.fileMap.delete(session.fileMap.keys().next().value);
  }
  session.fileMap.set(key, [logs, fileType, fileName]);
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

  // Owns the wire protocol - decode, reassemble, de-duplicate, file map - then
  // hands the result to the session's responder.
  app.patch("/respond", requireSecret, async (req, res) => {
    const token = req.body.token;
    let session;

    try {
      if (typeof req.body.data !== "string") {
        return res
          .status(400)
          .json({ message: "data must be a JSON-encoded string" });
      }

      session = getSession(token);
      if (!session) {
        return res.status(500).json({
          message: "Failed to deliver response",
          error: "Invalid or expired token",
        });
      }

      settleTasksForToken(token);

      const responseContent = decodeBuffer(JSON.parse(req.body.data)).toString(
        "utf-8",
      );
      const isLast = req.body.finished;
      const followUp = req.body.followUp;
      const runtime = req.body.runtime || 0;
      const serverNum = req.body.serverNum;
      const numSections = req.body.sections;
      const respondID = req.body.fileId;

      let { fileName, fileType } = parseFileType(req.body.fileType);

      let logs = req.body.log;

      if (logs) {
        if (numSections) {
          if (!Number.isInteger(numSections) || numSections > MAX_SECTIONS) {
            return res.status(400).json({
              message: `sections must be an integer <= ${MAX_SECTIONS}`,
            });
          }
          const result = await retrieveChunkedLogs(
            respondID,
            numSections,
            token,
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

      if (!getSession(token)) {
        return res.status(500).json({
          message: "Failed to deliver response",
          error: "Session ended before the response could be delivered",
        });
      }

      const isNewResponse = respondID > session.prevResponseId;
      if (isNewResponse) {
        session.prevResponseId = respondID;
      }

      if (logs && isNewResponse) {
        recordFile(session, fileName, fileType, logs);
      }

      const changedFileName =
        logs && isNewResponse ? `${fileName}.${fileType}` : null;

      if (isNewResponse) {
        await session.responder.deliver({
          responseContent,
          logs,
          fileName,
          fileType,
          changedFileName,
          fileMap: session.fileMap,
          isLast,
          runtime,
          serverNum,
          followUp,
        });
      }

      if (isLast) {
        closeSession(token);
      }

      res.json({
        message: "Successfully delivered response",
        data: "pass",
      });
    } catch (error) {
      logBot(
        "Respond Endpoint Error",
        `${error.message} stack: ${error.stack}`,
      );

      if (session) {
        await session.responder.fail(error, session.responder.link?.());
      }
      closeSession(token);

      res.status(500).json({
        message: "Failed to deliver response",
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
