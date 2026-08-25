const axios = require("axios");
const { RESOURCES_URL } = require("../config");

const CACHE_TTL_MS = 1000 * 60 * 5;

let resourcesCache = null;
let resourcesCacheTime = 0;

async function getResources() {
  if (resourcesCache && Date.now() - resourcesCacheTime < CACHE_TTL_MS) {
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

module.exports = { getResources, resourceDisplayName };
