import { tunnelmole } from "tunnelmole";
import { configDotenv } from "dotenv";
configDotenv();

async function getUrl() {
  const url = await tunnelmole({
    port: process.env.PORT,
  });
  console.log(`Tunnel URL: ${url}`);
}
getUrl();
 