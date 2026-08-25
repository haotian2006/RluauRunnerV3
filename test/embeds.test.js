const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createPendingResponseEmbed,
  createResponseEmbed,
} = require("../src/discord/embeds");

test("Lune results use the Lune runtime label without a server prefix", () => {
  const embed = createResponseEmbed("Lune", "user", "output", true, 1, null);
  assert.equal(embed.data.title, "Luau Compiler Results | Lune");
});

test("Roblox results retain their numbered server label", () => {
  const embed = createResponseEmbed(3, "user", "output", true, 1, null);
  assert.equal(embed.data.title, "Luau Compiler Results | Server #3");
});

test("pending results use a blank compiler embed without a runtime label", () => {
  const embed = createResponseEmbed(null, "user", "", false, 0, null);
  assert.equal(embed.data.title, "Luau Compiler Results");
  assert.match(embed.data.description, /```ansi\n \n```$/);
});

test("pending Roblox results show that the server is starting", () => {
  const embed = createPendingResponseEmbed("roblox", "user");
  assert.equal(embed.data.title, "Starting Server...");
  assert.match(embed.data.description, /```ansi\n \n```$/);
});

test("pending Lune results retain the Lune title", () => {
  const embed = createPendingResponseEmbed("lune", "user");
  assert.equal(embed.data.title, "Luau Compiler Results | Lune");
});
