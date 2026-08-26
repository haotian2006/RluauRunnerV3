const { generateAST } = require("../tools/luau");

// Lune's bundled Luau predates the `const` keyword (introduced in Luau
// 0.711); this repo's standalone `luau-ast` tool is fetched at "latest" and
// already parses it fine. Rather than a blind text replace (which could
// clobber "const" inside a string, comment, or identifier), we ask the AST
// for the exact byte position of each real `const` declaration and splice
// only those. "const" and "local" are both 5 bytes, so this never shifts
// any other location in the file.
async function desugarConstForLune(source) {
  let ast;
  try {
    const { output } = await generateAST(source);
    ast = JSON.parse(output);
  } catch {
    return source;
  }

  const positions = [];
  function walk(node) {
    if (!node || typeof node !== "object") return;
    if (
      node.type === "AstStatLocal" &&
      Array.isArray(node.vars) &&
      node.vars.some((v) => v?.isConst) &&
      typeof node.location === "string"
    ) {
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
