const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { PATH_TO_LUNE } = require("../src/config");
const { runLocal } = require("../src/local/run");

test(
  "Lune print formats tables like the Roblox executor",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal("print({ 1, 2, 3, 4 })", {
      timeoutMs: 5_000,
      onEvent(event) {
        events.push(event);
      },
    });

    assert.equal(result.ok, true);
    assert.deepEqual(events, [
      {
        t: "out",
        v: "{\n  [1] = 1,\n  [2] = 2,\n  [3] = 3,\n  [4] = 4,\n}\n",
      },
    ]);
  },
);

test(
  "Lune formats a table passed to error",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal("error({ 1, 2, 3, 4 })", {
      timeoutMs: 5_000,
      onEvent(event) {
        events.push(event);
      },
    });

    assert.equal(result.scriptErrored, true);
    assert.deepEqual(events, [
      {
        t: "error",
        v: "{\n  [1] = 1,\n  [2] = 2,\n  [3] = 3,\n  [4] = 4,\n}\n",
      },
    ]);
  },
);

test(
  "Lune io.writefile and io.readfile round-trip binary data",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal(
      'local data = "abc\\0"\nio.writefile(data, "note.txt")\nlocal read, name = io.readfile("note.txt")\nprint(name, #read, string.byte(read, 4))',
      {
        timeoutMs: 5_000,
        onEvent(event) {
          events.push(event);
        },
      },
    );

    assert.equal(result.ok, true);
    assert.deepEqual(events[0], {
      t: "file",
      name: "note.txt",
      hex: "61626300",
    });
    assert.deepEqual(events[1], { t: "out", v: "note.txt\t4\t0" });
  },
);

test(
  "Lune io.read receives binary Discord input",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal(
      "local data = io.read()\nprint(#data, string.byte(data, 1), string.byte(data, 3))",
      {
        timeoutMs: 5_000,
        onInputReady(sendInput) {
          sendInput(Buffer.from([0, 65, 255]));
        },
        onEvent(event) {
          events.push(event);
        },
      },
    );

    assert.equal(result.ok, true);
    assert.deepEqual(events, [{ t: "out", v: "3\t0\t255" }]);
  },
);
