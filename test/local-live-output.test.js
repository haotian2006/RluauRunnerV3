const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");

const { ENABLE_LOCAL_EXEC, PATH_TO_LUNE } = require("../src/config");
const { openSession } = require("../src/core/sessions");
const { classifyGlobal } = require("../src/local/keywords");
const {
  deliverLocalInput,
  localTimeoutForSelection,
  tryRunLocally,
} = require("../src/local/dispatch");

test("only forced Lune runs receive the one-minute timeout", () => {
  assert.equal(
    localTimeoutForSelection({ classification: { forced: true } }),
    60_000,
  );
  assert.equal(
    localTimeoutForSelection({ classification: { forced: false } }),
    30_000,
  );
  assert.equal(localTimeoutForSelection({ runtime: "lune" }), 30_000);
});

test(
  "Lune delivers partial output while yielding",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `live-output:${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    const ranLocally = await tryRunLocally(
      "--!lune\nprint(1)\ntask.wait(1.5)\nprint(2)",
      token,
      { actorKey: token },
    );

    assert.equal(ranLocally, true);
    const partial = deliveries.find((delivery) => !delivery.isLast);
    assert.ok(partial);
    assert.match(partial.responseContent, /1/);
    assert.doesNotMatch(partial.responseContent, /2/);

    const final = deliveries.at(-1);
    assert.equal(final.isLast, true);
    assert.match(final.responseContent, /1/);
    assert.match(final.responseContent, /2/);
  },
);

test(
  "Lune keeps only the latest 24 lines for a Discord responder",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `discord-lines:${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      outputLineLimit: 24,
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    await tryRunLocally(
      "--!lune\nfor index = 1, 30 do print(index) end",
      token,
      { actorKey: `discord:test-${token}:lune` },
    );

    const outputLines = deliveries.at(-1).responseContent.split("\n");
    assert.equal(outputLines.length, 24);
    assert.equal(outputLines[0], "7");
    assert.equal(outputLines.at(-1), "30");
  },
);

test(
  "Lune colors warnings and errors like the Roblox executor",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `colored-output:${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      outputLineLimit: 24,
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    await tryRunLocally('--!lune\nwarn(1)\nerror("bad")', token, {
      actorKey: `discord:test-${token}:lune`,
    });

    const output = deliveries.at(-1).responseContent;
    assert.match(output, /\u001b\[0;33m1\u001b\[0m/);
    assert.match(output, /\u001b\[0;31m.*bad.*\u001b\[0m/);
    assert.doesNotMatch(output, /\[(?:warning|error)\]/i);
  },
);

test(
  "Lune writefile is delivered as a Discord attachment",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const token = `local-file:${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    await tryRunLocally('--!lune\nio.writefile("hello", "note.txt")', token, {
      actorKey: `discord:test-${token}:lune`,
    });

    const fileDelivery = deliveries.find(
      (delivery) => delivery.changedFileName === "note.txt",
    );
    assert.ok(fileDelivery);
    assert.equal(fileDelivery.logs.toString("utf8"), "hello");
    assert.equal(fileDelivery.fileMap.get("note.txt")[1], "txt");
  },
);

test(
  "Discord input is forwarded to a waiting Lune io.read",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    const userId = `local-input-${Date.now()}`;
    const token = `local-input-token:${Date.now()}`;
    const deliveries = [];
    openSession(token, {
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    const run = tryRunLocally("--!lune\nprint(io.read())", token, {
      actorKey: `discord:${userId}:lune`,
    });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(deliverLocalInput(userId, "from discord"), 1);
    await run;

    assert.match(deliveries.at(-1).responseContent, /from discord/);
  },
);

test(
  "Lune discord clicks and follow-ups use the responder bridge",
  {
    skip: !ENABLE_LOCAL_EXEC || !fs.existsSync(PATH_TO_LUNE),
    timeout: 10_000,
  },
  async () => {
    assert.equal(classifyGlobal("discord"), null);
    const token = `local-button:${Date.now()}`;
    const deliveries = [];
    const buttonEvents = [];
    openSession(token, {
      isWeb: false,
      async updateButton(event, onClick) {
        buttonEvents.push(event);
        if (event.action === "create") {
          onClick({
            buttonId: event.buttonId,
            userId: "456",
            username: "clicker",
          });
        }
      },
      async deliver(payload) {
        deliveries.push(payload);
      },
      close() {},
    });

    await tryRunLocally(
      'local button = discord.button("Go")\nlocal id, name = button.Clicked:Wait()\nprint(id, name)\ndiscord.followUpNext()\nbutton:Destroy()',
      token,
      {
        actorKey: `discord:test-${token}:lune`,
        selection: { runtime: "lune" },
      },
    );

    assert.deepEqual(buttonEvents.map((event) => event.action), [
      "create",
      "delete",
    ]);
    assert.match(deliveries.at(-1).responseContent, /456\tclicker/);
    assert.equal(deliveries.at(-1).followUp, true);
  },
);
