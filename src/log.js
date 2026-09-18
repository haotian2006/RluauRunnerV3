const axios = require("axios");
const { FORM_ENTRIES, FORM_URL } = require("./config");
const { record, recordError } = require("./metrics");

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

// Also goes to stdout: the Google Form is write-only from here, so without
// this every diagnostic (router decisions, Discord retries, delivery failures)
// is invisible in `journalctl -u luau-bot`.
// Anything a category names as a failure is worth surfacing on the status page;
// the rest is routine chatter and only counted.
const FAILURE = /fail|error|crash|reject|lost|timed out|discard/i;

function logBot(name, data) {
  console.log(`[${name}] ${data}`);
  if (FAILURE.test(name)) recordError(name, String(data));
  else record("bot", name);
  log("0", "BOT", name, data);
}

module.exports = { log, logBot };
