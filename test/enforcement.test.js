const test = require("node:test");
const assert = require("node:assert/strict");
const express = require("express");

const { CRASHES_BEFORE_BLOCK, recordCrash } = require("../src/abuse");
const { sendCompileRequestToRoblox } = require("../src/discord/tasks");
const { registerWebRoutes } = require("../src/web");
const { hashIp } = require("../src/web/rateLimit");

function blockActor(actorKey) {
  for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
    recordCrash(actorKey, `test-outage:${actorKey}:${index}`);
  }
}

test("Discord rejects Roblox execution while its Roblox key is blocked", async () => {
  const userId = `blocked-${Date.now()}`;
  blockActor(`discord:${userId}:roblox`);

  const replies = [];
  const interaction = {
    token: `token-${userId}`,
    user: { id: userId, username: "blocked" },
    async editReply(value) {
      replies.push(value);
    },
  };

  await sendCompileRequestToRoblox(
    "print(game)",
    "interaction",
    interaction.token,
    "channel",
    null,
    interaction,
    null,
    true,
  );

  assert.equal(replies[0].content, null);
  assert.equal(replies[0].embeds[0].data.title, "Starting Server...");
  assert.match(
    replies.at(-1).content,
    /^Failed to start\. Try again <t:\d+:R>\.$/,
  );
});

test("web /run rejects Roblox execution while its Roblox key is blocked", async () => {
  const clientIp = "203.0.113.42";
  blockActor(`web:${hashIp(clientIp)}:roblox`);

  const app = express();
  app.use(express.json());
  registerWebRoutes(app);

  app.set("trust proxy", true);
  const server = await new Promise((resolve) => {
    const listening = app.listen(0, "127.0.0.1", () => resolve(listening));
  });

  try {
    const { port } = server.address();
    const response = await fetch(`http://127.0.0.1:${port}/run`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Forwarded-For": clientIp,
      },
      body: JSON.stringify({ code: "print(game)" }),
    });
    const body = await response.json();
    assert.equal(response.status, 429);
    assert.match(body.error, /^Failed to start\. Try again in \d+ seconds\.$/);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }
});
