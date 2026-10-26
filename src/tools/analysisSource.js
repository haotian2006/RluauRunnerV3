// Casts require's argument to any so analysis can't trace module paths into host files.
// Insertions add no newlines, so remap only shifts columns.
function prepareAnalysisSource(source, ast) {
  const bytes = Buffer.from(source, "utf8");
  const starts = [0];
  for (let i = 0; i < bytes.length; i++) if (bytes[i] === 10) starts.push(i + 1);
  const inserts = [];
  const seen = new Set();
  function visit(node) {
    if (!node || typeof node !== "object") return;
    if (node.type === "AstExprCall" && node.func?.type === "AstExprGlobal" && node.func.global === "require" && node.args?.length) {
      if (seen.has(node.args[0].location)) return;
      seen.add(node.args[0].location);
      const match = /^(\d+),(\d+) - (\d+),(\d+)$/.exec(node.args[0].location);
      if (!match) throw new Error("Cannot locate require argument for snippet analysis");
      const [, line, column, endLine, endColumn] = match.map(Number);
      inserts.push({line, column, offset: starts[line] + column, text: "("});
      inserts.push({line: endLine, column: endColumn, offset: starts[endLine] + endColumn, text: " :: any)"});
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach(visit);
      else if (value && typeof value === "object") visit(value);
    }
  }
  visit(ast?.root);
  let rewritten = bytes;
  for (const item of [...inserts].sort((a, b) => b.offset - a.offset)) {
    rewritten = Buffer.concat([rewritten.subarray(0, item.offset), Buffer.from(item.text), rewritten.subarray(item.offset)]);
  }
  return {
    source: rewritten.toString("utf8"),
    remap(output) {
      return output.replace(/^script\.luau\((\d+),(\d+)\):/gm, (_, line, column) => {
        let shifted = Number(column) - 1;
        for (const item of inserts.filter(i => i.line === Number(line) - 1).sort((a, b) => a.column - b.column)) {
          if (item.column < shifted) shifted -= Math.min(item.text.length, shifted - item.column);
        }
        return `script.luau(${line},${shifted + 1}):`;
      });
    },
  };
}
module.exports = { prepareAnalysisSource };
