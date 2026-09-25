const test = require("node:test");
const assert = require("node:assert/strict");

const { closeSession, openSession } = require("../src/core/sessions");
const { registerButtonRoutes } = require("../src/http/routes/buttons");
const { Inputs } = require("../src/state");
const { createSseResponder } = require("../src/web/sse");
const { registerWebRoutes } = require("../src/web/index");

function routesForTest(register) {
  const routes = {};
  const app = {
    set() {},
    get() {},
    post(path, ...handlers) {
      routes[`POST ${path}`] = handlers.at(-1);
    },
    patch(path, ...handlers) {
      routes[`PATCH ${path}`] = handlers.at(-1);
    },
  };
  register(app);
  return routes;
}

function responseForTest() {
  return {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

function streamForTest() {
  const events = [];
  return {
    events,
    writableEnded: false,
    write(chunk) {
      const match = /^event: (\w+)\ndata: (.*)\n\n$/s.exec(chunk);
      if (match) events.push([match[1], JSON.parse(match[2])]);
    },
    end() {
      this.writableEnded = true;
    },
    on() {},
  };
}

test("web responder tracks buttons, streams them, and clears them when the run ends", async () => {
  const responder = createSseResponder(null);
  const stream = streamForTest();
  responder.attach(stream);

  await responder.updateButton({ action: "create", buttonId: "b1", processId: "p1", label: "Run", style: "success" });
  await responder.updateButton({ action: "create", buttonId: "b2", processId: "p1", label: "Other" });
  await responder.updateButton({ action: "update", buttonId: "b1", processId: "p1", label: "Done", disabled: true });
  await responder.updateButton({ action: "delete", buttonId: "b2", processId: "p1" });

  const buttonEvents = stream.events.filter(([name]) => name === "buttons").map(([, data]) => data.buttons);
  assert.deepEqual(buttonEvents.at(-1), [{ id: "b1", label: "Done", style: "Success", disabled: true }]);
  assert.deepEqual(responder.snapshot().buttons, buttonEvents.at(-1));
  assert.equal(responder.clickButton("b1"), null, "disabled buttons cannot be clicked");
  assert.equal(responder.clickButton("b2"), null, "deleted buttons cannot be clicked");

  await responder.updateButton({ action: "update", buttonId: "b1", processId: "p1", disabled: false });
  assert.equal(responder.clickButton("b1").processId, "p1");

  await assert.rejects(
    responder.updateButton({ action: "delete", buttonId: "b1", processId: "other" }),
    /different process/,
  );
  await assert.rejects(
    responder.updateButton({ action: "create", buttonId: "b1", processId: "p1", label: "Again" }),
    /already exists/,
  );

  await responder.deliver({ responseContent: "", isLast: true, runtime: 1 });
  assert.deepEqual(responder.snapshot().buttons, []);
  assert.equal(responder.clickButton("b1"), null);
});

test("web responder enforces the Discord button cap", async () => {
  const responder = createSseResponder(null, { requireStream: false });
  for (let i = 0; i < 25; i++) {
    await responder.updateButton({ action: "create", buttonId: `b${i}`, processId: "p", label: `${i}` });
  }
  await assert.rejects(
    responder.updateButton({ action: "create", buttonId: "b25", processId: "p", label: "x" }),
    /at most 25/,
  );
});

test("Roblox button updates and web clicks route through the web session", async () => {
  const token = `web-button-${Date.now()}`;
  const responder = createSseResponder(null, { requireStream: false });
  openSession(token, responder);
  const buttonRoutes = routesForTest(registerButtonRoutes);
  const webRoutes = routesForTest(registerWebRoutes);
  const secret = { "x-secret-token": process.env.SECRET_TOKEN || "" };

  try {
    const update = responseForTest();
    await buttonRoutes["PATCH /button"]({
      headers: secret,
      body: { token, action: "create", buttonId: "btn-1", processId: "proc-1", label: "Click" },
    }, update);
    assert.equal(update.statusCode, 200, JSON.stringify(update.body));
    assert.deepEqual(responder.snapshot().buttons.map((b) => b.id), ["btn-1"]);

    const click = responseForTest();
    webRoutes["POST /button/:token"]({ params: { token }, body: { buttonId: "btn-1" }, ip: "127.0.0.1" }, click);
    assert.equal(click.statusCode, 200, JSON.stringify(click.body));
    const queued = Object.values(Inputs).find((input) => input.id === token && input.buttonId === "btn-1");
    assert.ok(queued, "click is queued for the Roblox server");
    assert.equal(queued.targetProcessId, "proc-1");
    assert.equal(queued.clickUserId, token);
    delete Inputs[queued.uid];

    const expired = responseForTest();
    webRoutes["POST /button/:token"]({ params: { token }, body: { buttonId: "missing" }, ip: "127.0.0.1" }, expired);
    assert.equal(expired.statusCode, 410);
  } finally {
    closeSession(token);
  }
});

test("Lune clicks on the web call the run's click handler", async () => {
  const token = `web-button-lune-${Date.now()}`;
  const responder = createSseResponder(null, { requireStream: false });
  openSession(token, responder);
  const clicks = [];
  try {
    await responder.updateButton(
      { action: "create", buttonId: "lune-1", processId: "lune-proc", label: "Hi" },
      (payload) => clicks.push(payload),
    );
    const res = responseForTest();
    routesForTest(registerWebRoutes)["POST /button/:token"]({ params: { token }, body: { buttonId: "lune-1" }, ip: "127.0.0.1" }, res);
    assert.equal(res.statusCode, 200);
    assert.equal(clicks.length, 1);
    assert.equal(clicks[0].buttonId, "lune-1");
    assert.equal(clicks[0].userId, token);
  } finally {
    closeSession(token);
  }
});
