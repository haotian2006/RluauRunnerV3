// Uses luau-analyze's unknown-global report, not a regex, so "game" in a
// string does not match. Every failure falls back to Roblox, which only costs
// latency; the reverse fails confusingly.

const { classifyGlobal, LUNE_DENIED_GLOBALS } = require("./keywords");
const { parseHotComments } = require("./hotComments");
const { findUnknownGlobals, generateAST } = require("../tools/luau");

// require/getfenv/loadstring are real Luau builtins, so they're invisible to
// findUnknownGlobals' report (verified: luau-analyze never flags them).
// Walk the AST directly for AstExprGlobal references to them instead, so a
// mention inside a string or comment doesn't false-positive like a regex
// scan would.
function findDeniedGlobalRefs(node, found) {
  if (!node || typeof node !== "object") return;
  if (node.type === "AstExprGlobal" && LUNE_DENIED_GLOBALS.has(node.global)) {
    found.add(node.global);
  }
  for (const key in node) {
    const value = node[key];
    if (Array.isArray(value)) value.forEach((child) => findDeniedGlobalRefs(child, found));
    else if (value && typeof value === "object") findDeniedGlobalRefs(value, found);
  }
}

async function findDeniedGlobals(source) {
  let ast;
  try {
    const { output } = await generateAST(source);
    ast = JSON.parse(output);
  } catch {
    return new Set();
  }
  const found = new Set();
  findDeniedGlobalRefs(ast.root, found);
  return found;
}

async function classify(source) {
  // Skips analysis if the user explicitly opts in to local execution.
  if (parseHotComments(source).lune) {
    return {
      eligible: true,
      forced: true,
      reason: null,
      detail: null,
      globals: {},
    };
  }

  let report;
  try {
    report = await findUnknownGlobals(source);
  } catch (err) {
    return {
      eligible: false,
      reason: "analyzer-unavailable",
      detail: err.message,
      globals: {},
    };
  }

  if (/SyntaxError/.test(report.output)) {
    return {
      eligible: false,
      reason: "syntax-error",
      detail: null,
      globals: {},
    };
  }

  const globals = {};
  let blocked = false;
  for (const name of report.names) {
    const kind = classifyGlobal(name);
    if (kind === null) continue;
    globals[name] = kind;
    blocked = true;
  }

  for (const name of await findDeniedGlobals(source)) {
    globals[name] = "roblox";
    blocked = true;
  }

  if (blocked) {
    return {
      eligible: false,
      reason: "unsupported-globals",
      detail: null,
      globals,
    };
  }

  return { eligible: true, reason: null, detail: null, globals: {} };
}

function describeClassification(result) {
  if (result.forced) return "local-eligible (--!lune)";
  if (result.eligible) return "local-eligible";
  const names = Object.keys(result.globals);
  if (names.length === 0) {
    return `roblox (${result.reason})`;
  }
  const shown = names
    .slice(0, 6)
    .map((name) => `${name}:${result.globals[name]}`)
    .join(", ");
  const rest = names.length > 6 ? `, +${names.length - 6} more` : "";
  return `roblox (${result.reason}: ${shown}${rest})`;
}

module.exports = { classify, describeClassification };
