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

test(
  "Lune require only returns reviewed sandbox modules",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal(
      'local serde = require("@lune/serde")\nprint(serde.encode("json", { safe = true }))',
      {
        timeoutMs: 5_000,
        onEvent(event) {
          events.push(event);
        },
      },
    );

    assert.equal(result.ok, true);
    assert.deepEqual(events, [{ t: "out", v: '{"safe":true}' }]);

    const deniedEvents = [];
    const denied = await runLocal('require("@lune/fs")', {
      timeoutMs: 5_000,
      onEvent(event) {
        deniedEvents.push(event);
      },
    });
    assert.equal(denied.scriptErrored, true);
    assert.match(deniedEvents[0].v, /not enabled in this sandbox/);
    assert.match(deniedEvents[0].v, /use the io global instead/);

    const robloxEvents = [];
    const robloxResult = await runLocal(
      'local roblox = require("@lune/roblox")\nprint(type(roblox.deserializePlace), type(roblox.Instance))\nprint(roblox.getAuthCookie, roblox.studioApplicationPath, roblox.studioContentPath, roblox.studioPluginPath, roblox.studioBuiltinPluginPath)',
      {
        timeoutMs: 5_000,
        onEvent(event) {
          robloxEvents.push(event);
        },
      },
    );
    assert.equal(robloxResult.ok, true);
    assert.deepEqual(robloxEvents, [
      { t: "out", v: "function\ttable" },
      { t: "out", v: "nil\tnil\tnil\tnil\tnil" },
    ]);
  },
);

test(
  "Lune getfenv and loadstring stay inside the sandbox",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal(
      'local invalid, syntaxError = loadstring("this is not valid (")\nprint(invalid == nil, type(syntaxError))\nlocal chunk, err = loadstring("return getfenv(0), require")\nassert(chunk, err)\nlocal env, nestedRequire = chunk()\nprint(env == getfenv(0), nestedRequire == require)\nlocal ok, message = pcall(nestedRequire, "@lune/fs")\nprint(ok, string.find(message, "not enabled", 1, true) ~= nil)',
      {
        timeoutMs: 5_000,
        onEvent(event) {
          events.push(event);
        },
      },
    );

    assert.equal(result.ok, true);
    assert.deepEqual(events, [
      { t: "out", v: "true\tstring" },
      { t: "out", v: "true\ttrue" },
      { t: "out", v: "false\ttrue" },
    ]);
  },
);

test(
  "Lune stdio wraps Discord input and output",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal(
      'local stdio = require("@lune/stdio")\nstdio.write("hello")\nstdio.ewrite("careful")\nprint(stdio.format({ 1, 2 }))\nprint(stdio.readLine(), stdio.readToEnd())\nprint(type(stdio.color), type(stdio.style), stdio.prompt)',
      {
        timeoutMs: 5_000,
        onInputReady(sendInput) {
          sendInput("first");
          sendInput("second");
        },
        onEvent(event) {
          events.push(event);
        },
      },
    );

    assert.equal(result.ok, true);
    assert.deepEqual(events, [
      { t: "out", v: "hello" },
      { t: "warn", v: "careful" },
      { t: "out", v: "{\n  [1] = 1,\n  [2] = 2,\n}\n" },
      { t: "out", v: "first\tsecond" },
      { t: "out", v: "function\tfunction\tnil" },
    ]);
  },
);

test(
  "Lune discord buttons receive typed clicks without consuming io input",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    let sendProtocolMessage;
    const result = await runLocal(
      'local button\nbutton = discord.button({ Label = "Run", Style = "Success" })\nbutton.Clicked:Connect(function(userId, username)\nprint(userId, username, io.read())\nbutton:Update({ Disabled = true })\ndiscord.followUpNext()\nbutton:Destroy()\nend)',
      {
        timeoutMs: 5_000,
        onInputReady(sendInput, sendMessage) {
          sendProtocolMessage = sendMessage;
          sendInput("kept input");
        },
        onEvent(event) {
          events.push(event);
          if (event.t === "button" && event.action === "create") {
            sendProtocolMessage({
              kind: "button",
              buttonId: event.buttonId,
              userId: "123",
              username: "tester",
            });
          }
        },
      },
    );

    assert.equal(result.ok, true);
    assert.equal(events[0].t, "button");
    assert.equal(events[0].action, "create");
    assert.equal(events[0].label, "Run");
    assert.equal(events[0].style, "Success");
    assert.deepEqual(events.slice(1).map((event) => event.t), [
      "out",
      "button",
      "followup",
      "button",
    ]);
    assert.equal(events[1].v, "123\ttester\tkept input");
    assert.equal(events[2].action, "update");
    assert.equal(events[2].disabled, true);
    assert.equal(events[4].action, "delete");
  },
);

test(
  "Lune discord buttons reject web runs",
  { skip: !fs.existsSync(PATH_TO_LUNE), timeout: 10_000 },
  async () => {
    const events = [];
    const result = await runLocal('discord.button("No")', {
      isWeb: true,
      timeoutMs: 5_000,
      onEvent(event) {
        events.push(event);
      },
    });

    assert.equal(result.scriptErrored, true);
    assert.match(events[0].v, /only available for runs started from Discord/);
  },
);
