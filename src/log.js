const axios = require("axios");
const { FORM_URL } = require("./config");

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

module.exports = { log, logBot };
