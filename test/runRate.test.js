const test = require("node:test");
const assert = require("node:assert/strict");

const { RUN_RATE_LIMIT, checkRunRate, runRateRetryMs } = require("../src/web/rateLimit");

test("a limited caller is told how long until their run window resets", () => {
  const ip = `rate-${Date.now()}`;
  for (let i = 0; i < RUN_RATE_LIMIT; i++) {
    assert.equal(runRateRetryMs(ip), 0);
    assert.equal(checkRunRate(ip), true);
  }
  assert.equal(checkRunRate(ip), false);
  const wait = runRateRetryMs(ip);
  assert.ok(wait > 0 && wait <= 60_000, `unexpected wait ${wait}`);
  // Rejected attempts don't count, so pressing Run again doesn't push the reset back.
  assert.equal(checkRunRate(ip), false);
  assert.ok(runRateRetryMs(ip) <= wait);
});
