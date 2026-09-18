const sessions = new Map();

function openSession(token, responder) {
  const session = { token, prevResponseId: 0, fileMap: null, responder };
  sessions.set(token, session);
  return session;
}

function getSession(token) {
  return sessions.get(token);
}

function closeSession(token) {
  const session = sessions.get(token);
  if (!session) return;
  sessions.delete(token);
  try {
    session.responder.close?.();
  } catch {}
}

function hasSession(token) {
  return sessions.has(token);
}

function sessionCount() {
  return sessions.size;
}

/** Live sessions by the surface that opened them. */
function sessionBreakdown() {
  const totals = { total: 0, web: 0, webStream: 0, webPoll: 0, discord: 0 };
  for (const session of sessions.values()) {
    totals.total += 1;
    const responder = session.responder;
    if (responder?.isWeb) {
      totals.web += 1;
      if (responder.mode === "poll") totals.webPoll += 1;
      else totals.webStream += 1;
    } else {
      totals.discord += 1;
    }
  }
  return totals;
}

module.exports = {
  openSession,
  getSession,
  closeSession,
  hasSession,
  sessionBreakdown,
  sessionCount,
};
