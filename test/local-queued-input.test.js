const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_LUNE } = require("../src/config");
const { MAX_PENDING_INPUTS, parseQueuedInputs } = require("../src/local/dispatch");
const { runLocal } = require("../src/local/run");

test("block and line directives are parsed in the Roblox executor's order", () => {
  assert.deepEqual(parseQueuedInputs("--[[@block one]]\n--@line one\nprint(1)"), [
    "block one",
    "line one",
  ]);
});

test("a block keeps its interior newlines", () => {
  assert.deepEqual(
    parseQueuedInputs("--[[@Hello, World!\n\naa\n]]\nlocal input = io.read()"),
    ["Hello, World!\n\naa\n"],
  );
});

test("--@ does not match the opening of a --[[@ block", () => {
  assert.deepEqual(parseQueuedInputs("--[[@only once]]"), ["only once"]);
});

test("source without directives queues nothing", () => {
  assert.deepEqual(parseQueuedInputs("print(1)"), []);
  assert.deepEqual(parseQueuedInputs(undefined), []);
});

// The Roblox executor scans raw source, so a directive inside a string counts
// there too. Matched deliberately: parity beats being cleverer than the original.
test("a directive inside a string is matched, as it is on the Roblox side", () => {
  assert.deepEqual(parseQueuedInputs("print('--@not really')"), ["not really')"]);
});

test("queued inputs are capped", () => {
  const source = "--@x\n".repeat(MAX_PENDING_INPUTS + 10);
  assert.equal(parseQueuedInputs(source).length, MAX_PENDING_INPUTS);
});

test(
  "a script with a queued input block reaches io.read on Lune",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 15_000 },
  async () => {
    const source =
      "--[[@Hello, World!\n\naa\n]]\nlocal input = io.read()\nprint(input)";
    const queued = parseQueuedInputs(source);
    const events = [];

    const result = await runLocal(source, {
      timeoutMs: 10_000,
      onInputReady(sendInput) {
        for (const value of queued) sendInput(value);
      },
      onEvent(event) {
        events.push(event);
      },
    });

    assert.equal(result.timedOut, false);
    assert.equal(result.ok, true);
    const printed = events
      .filter((event) => event.t === "out")
      .map((event) => event.v)
      .join("");
    assert.match(printed, /Hello, World!/);
  },
);
