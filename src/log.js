const axios = require("axios");
const { FORM_ENTRIES, FORM_URL } = require("./config");

const MAX_LOG_LENGTH = 20000 - 10;

/**
 * Report an event to the Google Form log
 * @param {string} userid
 * @param {string} name
 * @param {string} commandName
 * @param {string|number|undefined} data
 */
function log(userid, name, commandName, data) {
  if (data) {
    if (typeof data === "string" && data.length > MAX_LOG_LENGTH) {
      data = data.substring(0, MAX_LOG_LENGTH) + "... [truncated]";
    }
  }
  if (!FORM_URL) return;
  axios
    .post(
      FORM_URL,
      new URLSearchParams({
        [FORM_ENTRIES.name]: name,
        [FORM_ENTRIES.userId]: userid,
        [FORM_ENTRIES.command]: commandName,
        [FORM_ENTRIES.data]: data ? data : "",
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

module.exports = { log, logBot };
