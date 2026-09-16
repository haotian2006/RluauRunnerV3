const test = require("node:test");
const assert = require("node:assert/strict");

const {
  INPUT_CHUNK_MAX_PER_WINDOW,
  INPUT_MAX_PER_WINDOW,
  INPUT_WINDOW_MS,
  checkInputRate,
} = require("../src/abuse");

test("text inputs are capped per window and recover when it rolls over", () => {
  const actor = `web:text:${Date.now()}`;
  const startedAt = 5_000_000;

  for (let index = 0; index < INPUT_MAX_PER_WINDOW; index++) {
    assert.equal(checkInputRate(actor, "input", startedAt).allowed, true);
  }

  const blocked = checkInputRate(actor, "input", startedAt);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.limit, INPUT_MAX_PER_WINDOW);
  assert.equal(blocked.remainingMs, INPUT_WINDOW_MS);

  const afterWindow = startedAt + INPUT_WINDOW_MS;
  assert.equal(checkInputRate(actor, "input", afterWindow).allowed, true);
});

test("chunk uploads get their own, far larger budget", () => {
  const actor = `web:chunks:${Date.now()}`;
  const startedAt = 6_000_000;

  // A 100MB file at the 1MB chunk cap is 100 posts - it must not be throttled.
  for (let index = 0; index < 100; index++) {
    assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, true);
  }

  // Text budget is untouched by the chunk traffic.
  assert.equal(checkInputRate(actor, "input", startedAt).allowed, true);

  for (let index = 100; index < INPUT_CHUNK_MAX_PER_WINDOW; index++) {
    assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, true);
  }
  assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, false);
});

test("actors are limited independently", () => {
  const first = `discord:first:${Date.now()}`;
  const second = `discord:second:${Date.now()}`;
  const startedAt = 7_000_000;

  for (let index = 0; index < INPUT_MAX_PER_WINDOW; index++) {
    checkInputRate(first, "input", startedAt);
  }

  assert.equal(checkInputRate(first, "input", startedAt).allowed, false);
  assert.equal(checkInputRate(second, "input", startedAt).allowed, true);
});

test("a missing actor key is never blocked", () => {
  assert.equal(checkInputRate(undefined, "input", 8_000_000).allowed, true);
});
