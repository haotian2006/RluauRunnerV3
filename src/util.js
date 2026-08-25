const crypto = require("crypto");

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function generateUUID() {
  return crypto.randomBytes(8).toString("hex");
}

module.exports = { wait, generateUUID };
