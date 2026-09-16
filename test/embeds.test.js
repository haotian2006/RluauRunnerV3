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
  assert.match(embed.data.description, /```ansi/);
  assert.match(embed.data.description, /Running\.\.\./);
});

test("pending Roblox results show that the server is starting", () => {
  const embed = createPendingResponseEmbed("roblox", "user");
  assert.equal(embed.data.title, "Starting Server...");
  assert.match(embed.data.description, /```ansi/);
  assert.match(embed.data.description, /Running\.\.\./);
});

test("pending Lune results retain the Lune title", () => {
  const embed = createPendingResponseEmbed("lune", "user");
  assert.equal(embed.data.title, "Luau Compiler Results | Lune");
});

test("a finished run with no output says so instead of showing an empty block", () => {
  const embed = createResponseEmbed("Lune", "user", "", true, 0.3, null);
  assert.match(embed.data.description, /```ansi/);
  assert.match(embed.data.description, /No output/);
});

test("whitespace a script actually printed is not no output", () => {
  const embed = createResponseEmbed("Lune", "user", "   ", true, 0.3, null);
  assert.doesNotMatch(embed.data.description, /No output/);
});

test("a blank line a script printed is not no output", () => {
  const embed = createResponseEmbed("Lune", "user", "\n", true, 0.3, null);
  assert.doesNotMatch(embed.data.description, /No output/);
});

test("real output still renders in an ansi block", () => {
  const embed = createResponseEmbed("Lune", "user", "1 ", true, 0.3, null);
  assert.match(embed.data.description, /```ansi/);
  assert.match(embed.data.description, /1/);
});
