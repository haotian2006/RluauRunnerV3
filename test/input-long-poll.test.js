const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const { registerSessionRoutes } = require("../src/http/routes/session");
const { Inputs, putInput } = require("../src/state");

function getInputsRoute() {
  let route;
  registerSessionRoutes({
    get() {},
    post(path, ...handlers) {
      if (path === "/getInputs") route = handlers.at(-1);
    },
  });
  return route;
}

function responseForTest() {
  const res = new EventEmitter();
  res.statusCode = 200;
  res.body = undefined;
  res.status = (code) => {
    res.statusCode = code;
    return res;
  };
  res.json = (body) => {
    res.body = body;
    return res;
  };
  return res;
}

function clearInputs() {
  for (const key of Object.keys(Inputs)) delete Inputs[key];
}

test("getInputs answers at once when input is already queued", async () => {
  clearInputs();
  putInput({ uid: "queued", id: "user", input: "hi" });
  const res = responseForTest();
  const started = Date.now();
  await getInputsRoute()({ body: { i: [], wait: 20 } }, res);
  assert.ok(Date.now() - started < 500);
  assert.deepEqual(res.body.map((entry) => entry.uid), ["queued"]);
  clearInputs();
});

test("getInputs holds an empty poll until an input arrives", async () => {
  clearInputs();
  const res = responseForTest();
  const started = Date.now();
  const pending = getInputsRoute()({ body: { i: [], wait: 20 } }, res);
  setTimeout(() => putInput({ uid: "late", id: "user", input: "click" }), 150);
  await pending;
  const elapsed = Date.now() - started;
  assert.ok(elapsed >= 140 && elapsed < 2000, `woke after ${elapsed}ms`);
  assert.deepEqual(res.body.map((entry) => entry.uid), ["late"]);
  clearInputs();
});

test("getInputs skips inputs Roblox already processed and times out empty", async () => {
  clearInputs();
  putInput({ uid: "old", id: "user", input: "done" });
  const res = responseForTest();
  const started = Date.now();
  await getInputsRoute()({ body: { i: ["old"], wait: 0.2 } }, res);
  assert.ok(Date.now() - started >= 180);
  assert.deepEqual(res.body, []);
  clearInputs();
});

test("getInputs without wait keeps the old immediate reply", async () => {
  clearInputs();
  const res = responseForTest();
  const started = Date.now();
  await getInputsRoute()({ body: { i: [] } }, res);
  assert.ok(Date.now() - started < 100);
  assert.deepEqual(res.body, []);
});

test("getInputs stops waiting when Roblox disconnects", async () => {
  clearInputs();
  const res = responseForTest();
  const pending = getInputsRoute()({ body: { i: [], wait: 20 } }, res);
  setTimeout(() => res.emit("close"), 50);
  const started = Date.now();
  await pending;
  assert.ok(Date.now() - started < 1000);
  assert.equal(res.body, undefined, "no reply is written to a closed request");
});
