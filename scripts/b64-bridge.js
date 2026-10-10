// Loopback bridge for regenerating luauBot.b64 from Studio (see DEPLOYMENT.md).
// GET /source returns roblox/LuauBot.luau with LF endings; POST /output writes luauBot.b64.
// Exits after one successful write or after the timeout.
const fs = require("fs");
const http = require("http");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const PORT = Number(process.argv[2]) || 34570;
const TIMEOUT_MS = 5 * 60 * 1000;
const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/source") {
    const source = fs.readFileSync(path.join(ROOT, "roblox", "LuauBot.luau"), "utf8");
    return res.end(source.replace(/\r\n/g, "\n"));
  }
  if (req.method === "POST" && req.url === "/output") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const encoded = body.trim();
      if (!Buffer.from(encoded, "base64").subarray(0, 4).equals(ZSTD_MAGIC)) {
        res.statusCode = 400;
        return res.end("not a zstd payload");
      }
      fs.writeFileSync(path.join(ROOT, "luauBot.b64"), encoded);
      console.log(`wrote luauBot.b64 (${encoded.length} chars)`);
      res.end("ok", () => process.exit(0));
    });
    return;
  }
  res.statusCode = 404;
  res.end();
});

server.listen(PORT, "127.0.0.1", () => console.log(`b64 bridge on 127.0.0.1:${PORT}`));
setTimeout(() => {
  console.log("timed out without a write");
  process.exit(1);
}, TIMEOUT_MS).unref();
