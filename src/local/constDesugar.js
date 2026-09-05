const { generateAST } = require("../tools/luau");

async function desugarConstForLune(source) {
  let ast;
  try {
    const { output } = await generateAST(source);
    ast = JSON.parse(output);
  } catch {
    return source;
  }

  function isConstDeclaration(node) {
    if (node.type === "AstStatLocal") {
      return Array.isArray(node.vars) && node.vars.some((v) => v?.isConst);
    }
    if (node.type === "AstStatLocalFunction") {
      return node.name?.isConst === true;
    }
    return false;
  }

  const positions = [];
  function walk(node) {
    if (!node || typeof node !== "object") return;
    if (isConstDeclaration(node) && typeof node.location === "string") {
      const [line, col] = node.location.split(" - ")[0].split(",").map(Number);
      if (Number.isInteger(line) && Number.isInteger(col)) {
        positions.push({ line, col });
      }
    }
    for (const key in node) {
      const value = node[key];
      if (Array.isArray(value)) value.forEach(walk);
      else if (value && typeof value === "object") walk(value);
    }
  }
  walk(ast.root);

  if (positions.length === 0) return source;

  const lines = source.split("\n");
  for (const { line, col } of positions) {
    const text = lines[line];
    if (text === undefined || text.slice(col, col + 5) !== "const") continue;
    lines[line] = text.slice(0, col) + "local" + text.slice(col + 5);
  }

  return lines.join("\n");
}

module.exports = { desugarConstForLune };
