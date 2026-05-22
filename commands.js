require("dotenv").config();
const https = require("follow-redirects").https;

const TOKEN = process.env.BOT_TOKEN;
const CLIENT_ID = process.env.CLIENT_ID;

const commands = [
  {
    name: "ping",
    description: "Replies with Pong!",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
  },
  {
    name: "tag",
    description: "retrieves a resource",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
    options: [
      {
        name: "resource",
        description: "name of the resource to view",
        type: 3,
        required: true,
        autocomplete: true,
      },
      {
        name: "target",
        description: "User to mention",
        type: 6,
        required: false,
      },
    ],
  },

  {
    name: "stopall",
    description: "Stops all running sessions that you own",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
  },
  {
    name: "help",
    description: "check out this site!",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
  },
  {
    name: "compile",
    description: "Runs rLuau code in roblox",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
    options: [
      {
        name: "code",
        description: "Code to run",
        type: 3,
        required: true,
      },
    ],
  },
  {
    name: "input",
    description: "Provides input for io.read()",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
    options: [
      {
        name: "input",
        description: "input string",
        type: 3,
        required: false,
      },
    ],
  },
  {
    name: "hiddeninput",
    description: "Provides input for io.read() without showing it to others",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 1,
    options: [
      {
        name: "input",
        description: "input string",
        type: 3,
        required: false,
      },
    ],
  },
  {
    name: "compile",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "input",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "bytecode",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  // { // re assemble using konstant BROKEN FOR NOW
  //   name: "bytecodeK",
  //   integration_types: [0,1],
  //   contexts: [0, 1, 2],
  //   type: 3,
  // },
  {
    name: "bytecodeWOption",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "compileWOption",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "analyze",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "ast",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  {
    name: "format",
    integration_types: [0, 1],
    contexts: [0, 1, 2],
    type: 3,
  },
  // { // decompile using konstant BROKEN FOR NOW
  //   name: "decompile",
  //   integration_types: [0,1],
  //   contexts: [0, 1, 2],
  //   type: 3,
  // },
];

function httpsRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function deregisterCommand(name) {
  const listRes = await httpsRequest({
    method: "GET",
    hostname: "discord.com",
    path: `/api/v10/applications/${CLIENT_ID}/commands`,
    headers: { Authorization: `Bot ${TOKEN}` },
  });

  if (listRes.statusCode !== 200) {
    console.warn(`Failed to fetch commands: ${listRes.statusCode}`);
    return;
  }

  const existing = JSON.parse(listRes.body);
  const match = existing.find((c) => c.name === name);
  if (!match) {
    console.log(`Command "${name}" not found, nothing to deregister.`);
    return;
  }

  const delRes = await httpsRequest({
    method: "DELETE",
    hostname: "discord.com",
    path: `/api/v10/applications/${CLIENT_ID}/commands/${match.id}`,
    headers: { Authorization: `Bot ${TOKEN}` },
  });

  if (delRes.statusCode === 204) {
    console.log(`Deregistered command: ${name}`);
  } else {
    console.warn(`Failed to deregister "${name}": ${delRes.statusCode} ${delRes.body}`);
  }
}

async function registerCommands() {
 

  for (const command of commands) {
    const data = JSON.stringify(command);

    const options = {
      method: "POST",
      hostname: "discord.com",
      path: `/api/v10/applications/${CLIENT_ID}/commands`,
      headers: {
        Authorization: `Bot ${TOKEN}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(data),
      },
    };

    await new Promise((resolve) => {
      const req = https.request(options, (res) => {
        let body = "";
        res.on("data", (chunk) => {
          body += chunk;
        });
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            console.log(`Registered command: ${command.name}`);
          } else {
            console.warn(`Failed to register command: ${command.name}`);
            console.warn(`Status: ${res.statusCode} ${res.statusMessage}`);
            console.warn("Response:", body);
          }
          setTimeout(resolve, 2500);
        });
      });

      req.on("error", (error) => {
        console.error(`Error registering command ${command.name}:`, error);
        setTimeout(resolve, 2500);
      });

      req.write(data);
      req.end();
    });
  }
}

registerCommands();
