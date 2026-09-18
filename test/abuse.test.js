const test = require("node:test");
const assert = require("node:assert/strict");

const {
  BLOCK_DURATION_MS,
  CRASHES_BEFORE_BLOCK,
  ESCALATION_RESET_MS,
  MAX_BLOCK_DURATION_MS,
  CRASH_WINDOW_MS,
  LOCAL_MAX_PER_ACTOR,
  LOCAL_STALE_AFTER_MS,
  LOCAL_STALE_BLOCK_MS,
  acquireLocalExecution,
  finishLocalExecutionHealth,
  getActorBlock,
  getLocalAdmissionBlock,
  heartbeatLocalExecution,
  isPunishableLuneExit,
  recordCrash,
  releaseLocalExecution,
  startLocalExecutionHealth,
} = require("../src/abuse");

test("third distinct crash in two minutes blocks an actor for 45 seconds", () => {
  const actor = `test:threshold:${Date.now()}`;
  const startedAt = 1_000_000;

  for (let index = 0; index < CRASHES_BEFORE_BLOCK - 1; index++) {
    const result = recordCrash(actor, `server:${index}`, [], startedAt + index);
    assert.equal(result.count, index + 1);
    assert.equal(result.blockedUntil, 0);
  }

  const thirdAt = startedAt + CRASHES_BEFORE_BLOCK;
  const result = recordCrash(actor, "server:third", ["hash"], thirdAt);
  assert.equal(result.count, CRASHES_BEFORE_BLOCK);
  assert.equal(result.blockedUntil, thirdAt + BLOCK_DURATION_MS);
  assert.equal(getActorBlock(actor, thirdAt).remainingMs, BLOCK_DURATION_MS);
});

test("one server outage counts once per actor and old strikes decay", () => {
  const actor = `test:dedupe:${Date.now()}`;
  const startedAt = 2_000_000;

  recordCrash(actor, "same-server", ["one"], startedAt);
  const duplicate = recordCrash(actor, "same-server", ["two"], startedAt + 1);
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.count, 1);

  const afterWindow = startedAt + CRASH_WINDOW_MS + 1;
  const fresh = recordCrash(actor, "new-server", [], afterWindow);
  assert.equal(fresh.count, 1);
});

test("runtime-scoped crash blocks do not cross from Lune to Roblox", () => {
  const actor = `discord:runtime-split-${Date.now()}`;
  const luneActor = `${actor}:lune`;
  const robloxActor = `${actor}:roblox`;

  for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
    recordCrash(luneActor, `lune-crash:${index}`);
  }

  assert.ok(getActorBlock(luneActor));
  assert.equal(getActorBlock(robloxActor), null);
});

test("Lune permits ten active or queued executions per actor", () => {
  const actor = `test:lune:${Date.now()}`;

  for (let index = 0; index < LOCAL_MAX_PER_ACTOR; index++) {
    assert.equal(acquireLocalExecution(actor), true);
  }
  assert.equal(acquireLocalExecution(actor), false);

  releaseLocalExecution(actor);
  assert.equal(acquireLocalExecution(actor), true);

  for (let index = 0; index < LOCAL_MAX_PER_ACTOR; index++) {
    releaseLocalExecution(actor);
  }
});

test("a bot-enforced Lune timeout is flagged but not punished", () => {
  assert.equal(
    isPunishableLuneExit({ timedOut: true, abnormalExit: false }),
    false,
  );
  assert.equal(
    isPunishableLuneExit({ timedOut: false, abnormalExit: true }),
    true,
  );
});

test("two unresponsive Lune runs block new admission for 11 seconds", () => {
  const actor = `discord:stalled-${Date.now()}:lune`;
  const startedAt = 5_000_000;

  startLocalExecutionHealth(actor, "first", startedAt);
  startLocalExecutionHealth(actor, "second", startedAt);
  assert.equal(
    getLocalAdmissionBlock(actor, startedAt + LOCAL_STALE_AFTER_MS - 1),
    null,
  );

  const block = getLocalAdmissionBlock(actor, startedAt + LOCAL_STALE_AFTER_MS);
  assert.equal(block.remainingMs, LOCAL_STALE_BLOCK_MS);

  finishLocalExecutionHealth(actor, "first");
  finishLocalExecutionHealth(actor, "second");
});

test("a heartbeat keeps one of two Lune runs from triggering admission block", () => {
  const actor = `discord:healthy-${Date.now()}:lune`;
  const startedAt = 6_000_000;
  const checkedAt = startedAt + LOCAL_STALE_AFTER_MS;

  startLocalExecutionHealth(actor, "first", startedAt);
  startLocalExecutionHealth(actor, "second", startedAt);
  heartbeatLocalExecution(actor, "second", checkedAt);

  assert.equal(getLocalAdmissionBlock(actor, checkedAt), null);

  finishLocalExecutionHealth(actor, "first");
  finishLocalExecutionHealth(actor, "second");
});

test("a repeat offender's block doubles each time", () => {
  const actor = "web:escalating";
  const at = 10_000_000;

  function blockOnce(start, tag) {
    let result;
    for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
      result = recordCrash(actor, `${tag}:${index}`, [], start + index);
    }
    return result;
  }

  const first = blockOnce(at, "a");
  assert.equal(first.durationMs, BLOCK_DURATION_MS);
  assert.equal(first.blocks, 1);

  // Far enough out that the earlier incidents have aged out of the window, so
  // this is a second offence rather than the first one continuing.
  const second = blockOnce(at + CRASH_WINDOW_MS * 2, "b");
  assert.equal(second.durationMs, BLOCK_DURATION_MS * 2);
  assert.equal(second.blocks, 2);

  const third = blockOnce(at + CRASH_WINDOW_MS * 4, "c");
  assert.equal(third.durationMs, BLOCK_DURATION_MS * 4);
  assert.equal(third.blocks, 3);
});

test("the escalation stops at the ceiling", () => {
  const actor = "web:ceiling";
  let at = 20_000_000;
  let result;
  for (let round = 0; round < 12; round++) {
    for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
      result = recordCrash(actor, `r${round}:${index}`, [], at + index);
    }
    at += CRASH_WINDOW_MS * 2;
  }
  assert.equal(result.durationMs, MAX_BLOCK_DURATION_MS);
});

test("behaving for long enough clears the escalation", () => {
  const actor = "web:forgiven";
  const at = 30_000_000;
  for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
    recordCrash(actor, `first:${index}`, [], at + index);
  }

  const later = at + ESCALATION_RESET_MS + 1;
  assert.equal(getActorBlock(actor, later), null);

  let result;
  for (let index = 0; index < CRASHES_BEFORE_BLOCK; index++) {
    result = recordCrash(actor, `second:${index}`, [], later + index);
  }
  assert.equal(result.durationMs, BLOCK_DURATION_MS, "back to a first offence");
  assert.equal(result.blocks, 1);
});
