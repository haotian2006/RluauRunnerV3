const test = require("node:test");
const assert = require("node:assert/strict");

const { describe: describeReason } = require("../src/safety");

test("an Error is reported with its message and stack", () => {
  const text = describeReason(new Error("Invalid Form Body"));
  assert.match(text, /Invalid Form Body/);
  assert.match(text, /at /);
});

test("a non-Error rejection is still reportable", () => {
  assert.equal(describeReason({ code: 50035 }), '{"code":50035}');
  assert.equal(describeReason("plain"), '"plain"');
});

test("a value that cannot be serialised does not throw", () => {
  const circular = {};
  circular.self = circular;
  assert.doesNotThrow(() => describeReason(circular));
});

test("an unhandled rejection is survivable, an uncaught exception is fatal", () => {
  const listeners = {};
  const realOn = process.on.bind(process);
  process.on = (event, handler) => {
    if (event === "unhandledRejection" || event === "uncaughtException") {
      listeners[event] = handler;
      return process;
    }
    return realOn(event, handler);
  };

  try {
    let fatal = 0;
    require("../src/safety").installSafetyNets(() => {
      fatal += 1;
    });

    listeners.unhandledRejection(new Error("Invalid Form Body"));
    assert.equal(fatal, 0, "a rejected promise must not take the process down");

    listeners.uncaughtException(new Error("corrupt state"));
    assert.equal(fatal, 1, "an uncaught exception hands over to systemd");
  } finally {
    process.on = realOn;
  }
});
