const test = require("node:test");
const assert = require("node:assert/strict");

const {
  INPUT_CHUNK_MAX_PER_WINDOW,
  INPUT_MAX_PER_WINDOW,
  INPUT_WINDOW_MS,
  STUDIO_INPUT_MAX_PER_WINDOW,
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

  // A 100MB file in 1MB chunks is 100 posts; none may be throttled.
  for (let index = 0; index < 100; index++) {
    assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, true);
  }

  // Chunks don't use the text budget.
  assert.equal(checkInputRate(actor, "input", startedAt).allowed, true);

  for (let index = 100; index < INPUT_CHUNK_MAX_PER_WINDOW; index++) {
    assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, true);
  }
  assert.equal(checkInputRate(actor, "chunk", startedAt).allowed, false);
});

test("inputs to runs on Studio workers get their own, larger budget", () => {
  const actor = `web:studio:${Date.now()}`;
  const startedAt = 6_500_000;

  assert.ok(STUDIO_INPUT_MAX_PER_WINDOW > INPUT_MAX_PER_WINDOW);
  for (let index = 0; index < STUDIO_INPUT_MAX_PER_WINDOW; index++) {
    assert.equal(checkInputRate(actor, "studio", startedAt).allowed, true);
  }
  const blocked = checkInputRate(actor, "studio", startedAt);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.limit, STUDIO_INPUT_MAX_PER_WINDOW);

  // Studio inputs don't use the text budget.
  assert.equal(checkInputRate(actor, "input", startedAt).allowed, true);
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
