const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const { isWorkerPath } = require("../src/http/server");
const { Inputs, putInput } = require("../src/state");
const { notifyWorkers, openWorkerStream } = require("../src/workerEvents");

function openStream() {
  const req = new EventEmitter();
  const res = Object.assign(new EventEmitter(), { status: null, written: [] });
  res.writeHead = (status, headers) => {
    res.status = status;
    res.headers = headers;
  };
  res.write = (chunk) => res.written.push(chunk);
  openWorkerStream(req, res);
  return { req, res };
}

test("workerEvents opens an event stream", () => {
  const { res } = openStream();
  assert.equal(res.status, 200);
  assert.equal(res.headers["Content-Type"], "text/event-stream");
  res.emit("close");
});

test("queued inputs and tasks wake open streams", () => {
  const { res } = openStream();
  putInput({ uid: "wake-test", id: "user", input: "hi" });
  notifyWorkers("task");
  assert.ok(res.written.includes("event: input\ndata: {}\n\n"));
  assert.ok(res.written.includes("event: task\ndata: {}\n\n"));
  res.emit("close");
  delete Inputs["wake-test"];
});

test("a closed stream gets nothing more", () => {
  const { res } = openStream();
  res.emit("close");
  const before = res.written.length;
  notifyWorkers("task");
  assert.equal(res.written.length, before);
});

test("the worker socket serves only worker routes", () => {
  for (const url of ["/getNext", "/respond", "/workerEvents", "/asset/123?size=420", "/github?url=x"]) {
    assert.ok(isWorkerPath(url), url);
  }
  for (const url of ["/", "/status", "/status/data", "/run", "/result/abc", "/source/1", "/stats", "/GETNEXT"]) {
    assert.ok(!isWorkerPath(url), url);
  }
});
