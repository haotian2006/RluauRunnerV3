const DEFAULT_OPTIMIZATION_LEVEL = 1;

function parseHotComments(source) {
  const result = {
    optimizationLevel: DEFAULT_OPTIMIZATION_LEVEL,
    native: false,
    lune: false,
  };

  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === "") continue;
    if (!line.startsWith("--")) break;

    const optimize = /^--!optimize\s+([0-2])\s*$/.exec(line);
    if (optimize) {
      result.optimizationLevel = Number(optimize[1]);
    } else if (/^--!native\s*$/.test(line)) {
      result.native = true;
    } else if (/^--!lune\s*$/.test(line)) {
      result.lune = true;
    }
  }

  return result;
}

module.exports = { parseHotComments, DEFAULT_OPTIMIZATION_LEVEL };
