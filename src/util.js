function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function generateUUID() {
  return Math.random().toString(36).substring(2, 10);
}

module.exports = { wait, generateUUID };
