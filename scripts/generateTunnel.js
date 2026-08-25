// Prints a public URL to put in CALLBACK_URL for testing. Pass a port, or set PORT.
const tunnelmole = require("tunnelmole/cjs");

const port = Number(process.argv[2] || process.env.PORT || 3000);

tunnelmole({ port })
  .then((url) => console.log(url))
  .catch((err) => {
    console.error("Failed to open tunnel:", err.message);
    process.exit(1);
  });
