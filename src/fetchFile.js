const { https } = require("follow-redirects");

/**
 * Hard ceiling on anything we pull down from Discord.
 *
 * Aligned with `MAX_DATA_TO_SEND` in config.js, which is the limit that
 * actually governs this path: an input is zstd-compressed and then gated on
 * its *compressed* size, so the raw file is allowed to be as large as the
 * compressed budget. This is a bound on memory per download, not the real
 * admission check.
 */
const MAX_DOWNLOAD_BYTES = 100 * 1024 * 1024;

const MAX_REDIRECTS = 3;

class DownloadTooLargeError extends Error {
  constructor(limit) {
    super(`File exceeds the maximum size of ${Math.floor(limit / 1024)} KB`);
    this.name = "DownloadTooLargeError";
    this.limit = limit;
  }
}

function fetchBuffer(url, maxBytes = MAX_DOWNLOAD_BYTES) {
  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      { maxRedirects: MAX_REDIRECTS },
      (response) => {
        if (response.statusCode !== 200) {
          response.resume();
          reject(
            new Error(
              `Failed to get data. Status Code: ${response.statusCode}`,
            ),
          );
          return;
        }

        const declared = Number(response.headers["content-length"]);
        if (Number.isFinite(declared) && declared > maxBytes) {
          response.destroy();
          reject(new DownloadTooLargeError(maxBytes));
          return;
        }

        const chunks = [];
        let received = 0;

        response.on("data", (chunk) => {
          received += chunk.length;
          if (received > maxBytes) {
            response.destroy();
            reject(new DownloadTooLargeError(maxBytes));
            return;
          }
          chunks.push(chunk);
        });

        response.on("end", () => {
          resolve(Buffer.concat(chunks));
        });

        response.on("error", reject);
      },
    );
    request.on("error", reject);
  });
}

async function fetchFileContent(url, maxBytes = MAX_DOWNLOAD_BYTES) {
  const buffer = await fetchBuffer(url, maxBytes);
  return buffer.toString("utf-8");
}

async function fetchBinaryFile(url, maxBytes = MAX_DOWNLOAD_BYTES) {
  return await fetchBuffer(url, maxBytes);
}

module.exports = { MAX_DOWNLOAD_BYTES, fetchFileContent, fetchBinaryFile };
