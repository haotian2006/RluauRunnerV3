const test = require("node:test");
const assert = require("node:assert/strict");

const { recordCrash } = require("../src/abuse");
const { recordServerOutage } = require("../src/roblox/session");
const { ActiveRobloxTasks } = require("../src/state");

test("a server that keeps missing heartbeats is one strike for the actor, not one per lapse", () => {
  const actorKey = `web:outage-${Date.now()}:roblox`;
  const serverId = `server-${Date.now()}`;
  ActiveRobloxTasks["outage-task"] = { serverId, task: { actorKey, codeHash: "abc" } };
  try {
    // Each lapse used to arrive with a new lastPing, which made it look like a new incident.
    for (let lapse = 0; lapse < 5; lapse++) recordServerOutage(serverId, Date.now() + lapse * 7000);
    // A different server is a new incident, which makes this the second strike.
    assert.equal(recordCrash(actorKey, "roblox:another-server").count, 2);
  } finally {
    delete ActiveRobloxTasks["outage-task"];
  }
});
