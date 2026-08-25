const { SECRET_TOKEN } = require("../state");

function requireSecret(req, res, next) {
  if (req.headers["x-secret-token"] !== SECRET_TOKEN) {
    return res.status(403).json({ message: "Forbidden" });
  }
  next();
}

module.exports = { requireSecret };
