const { compileLuau } = require("./luau");

function getAnalysisOptions(code) {
  if (!code) {
    code = "";
  }
  const annotateMatch = code.match("--!annotate");

  return {
    annotate: !!annotateMatch,
  };
}

/**
 * Read the `--!optimize` / `--!debug` / `--!native` style directives out of the
 * source and turn them into compiler options.
 * @param {string?} code
 */
function getByteCodeOptions(code) {
  if (!code) {
    code = "";
  }
  const oMatch = code.match("--!optimize (\\d+)");
  const dMatch = code.match("--!debug (\\d+)");
  const aMatch = code.match("--!architecture (\\S+)");
  let options = {
    architecture: aMatch ? aMatch[1] : "x64",
    native: code.indexOf("--!native") !== -1,
    binary: code.indexOf("--!binary") !== -1,
    remarks: code.indexOf("--!remarks") !== -1,
    constants: code.indexOf("--!dump-constants") !== -1,
    optimizeLevel: oMatch ? parseInt(oMatch[1]) : 2,
    debugLevel: dMatch ? parseInt(dMatch[1]) : 0,
  };
  if (options.native || options.remarks) {
    options.binary = false;
  }
  options.optimizeLevel = Math.max(0, Math.min(2, options.optimizeLevel));
  options.debugLevel = Math.max(0, Math.min(2, options.debugLevel));
  return options;
}

function byteCodeOptionsToString(options) {
  let str = "";
  if (options.remarks && !options.binary) {
    str += "Remarks: Enabled\n";
  }
  if (options.native) {
    str += "Native Codegen: Enabled\n";
    str += `Architecture: ${options.architecture}\n`;
  }
  str += `OptimizeLevel: ${options.optimizeLevel}\n`;
  str += `DebugLevel: ${options.debugLevel}\n`;
  str += "-------------------\n";
  return str;
}

async function getByteCode(options, code) {
  const result = await compileLuau(code, options);
  return result.output;
}

module.exports = {
  getAnalysisOptions,
  getByteCodeOptions,
  byteCodeOptionsToString,
  getByteCode,
};
