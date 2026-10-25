const { loadUserData, saveUserData, userForToken } = require("../../dataStores");
const { requireSecret } = require("../middleware");

// Worker routes for persistent DataStores. Both need the worker secret and a run's private
// storage token (x-storage-token), which picks the user.
function registerDataStoreRoutes(app) {
  const userOf = (req, res) => {
    const userId = userForToken(req.headers["x-storage-token"]);
    if (!userId) res.status(403).json({ message: "Storage token unknown or expired" });
    return userId;
  };

  app.post("/dataStore/load", requireSecret, async (req, res) => {
    const userId = userOf(req, res);
    if (!userId) return;
    try {
      res.json(await loadUserData(userId));
    } catch (err) {
      res.status(500).json({ message: `DataStore load failed: ${err.message}` });
    }
  });

  app.post("/dataStore/save", requireSecret, async (req, res) => {
    const userId = userOf(req, res);
    if (!userId) return;
    try {
      const { status, ...body } = await saveUserData(userId, req.body?.changes);
      res.status(status).json(body);
    } catch (err) {
      res.status(500).json({ message: `DataStore save failed: ${err.message}` });
    }
  });
}

module.exports = { registerDataStoreRoutes };
