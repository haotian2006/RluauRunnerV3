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

module.exports = { openSession, getSession, closeSession, hasSession };
