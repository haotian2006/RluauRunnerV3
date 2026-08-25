const test = require("node:test");
const assert = require("node:assert/strict");

const { needsAdditionalWorker } = require("../src/roblox/session");

test("queued work starts another worker when the current worker is unhealthy", () => {
  const workers = [{ healthy: false, retiring: false }];
  assert.equal(needsAdditionalWorker(workers, 1, 0), true);
});

test("a recovered worker can take the next queued task", () => {
  const workers = [{ healthy: true, retiring: false }];
  assert.equal(needsAdditionalWorker(workers, 1, 0), false);
});

test("a pending worker prevents duplicate scale-up", () => {
  const workers = [{ healthy: false, retiring: false }];
  assert.equal(needsAdditionalWorker(workers, 1, 1), false);
});
