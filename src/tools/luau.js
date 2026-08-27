const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

function missingToolError(executablePath) {
  const name = path.basename(executablePath);
  return new Error(
    `${name} is not installed. Run \`npm run fetch-tools\` to download the luau tools.`,
  );
}

const {
  PATH_TO_ANALYZER,
  PATH_TO_AST,
  PATH_TO_COMPILER,
  PATH_TO_FORMATTER,
} = require("../config");

const DISPLAY_NAME = "script.luau";
const TOOL_TIMEOUT_MS = 10000;
const KILL_GRACE_MS = 1000;

function stripTempPaths(output, tmpDir, inputPath) {
  if (!output) return output;

  // luau emits forward slashes; stylua uses the OS form.
  const variants = (value) => [
    value,
    value.replace(/\\/g, "/"),
    value.replace(/\//g, "\\"),
  ];

  let result = output;
  for (const variant of variants(inputPath)) {
    result = result.split(variant).join(DISPLAY_NAME);
  }
  for (const variant of variants(tmpDir)) {
    result = result.split(variant).join(".");
  }
  return result;
}

async function execute(executablePath, code, args) {
  return new Promise((resolve, reject) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-"));

    const inputPath = path.join(tmpDir, "Code.luau");
    const outputPath = path.join(tmpDir, "Output.luau");

    fs.writeFileSync(inputPath, code, "utf8");

    args.push(inputPath);

    const outputStream = fs.createWriteStream(outputPath);

    const child = spawn(executablePath, args);

    // Both child streams share one destination. Neither pipe may close it on
    // its own, because the other stream can still have buffered data to write.
    child.stdout.pipe(outputStream, { end: false });
    child.stderr.pipe(outputStream, { end: false });

    let timedOut = false;
    let killTimer = null;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
    }, TOOL_TIMEOUT_MS);

    outputStream.on("error", (err) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      child.kill("SIGKILL");
      reject(err);
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      reject(err.code === "ENOENT" ? missingToolError(executablePath) : err);
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      outputStream.end(() => {
        const output = timedOut
          ? "Timed out"
          : fs.readFileSync(outputPath, "utf8");

        try {
          fs.unlinkSync(inputPath);
          fs.unlinkSync(outputPath);
          fs.rmdirSync(tmpDir);
        } catch {}

        resolve({
          code: timedOut ? -1 : code,
          output: stripTempPaths(output, tmpDir, inputPath),
        });
      });
    });
  });
}

async function analyzeLuau(code, options) {
  const args = [];
  args.push("--annotate");
  args.push("--fflags=LuauSolverV2=true");

  return await execute(PATH_TO_ANALYZER, code, args);
}

async function generateAST(code) {
  return await execute(PATH_TO_AST, code, []);
}
async function findUnknownGlobals(code) {
  const result = await execute(PATH_TO_ANALYZER, code, []);
  const names = new Set();
  const pattern = /Unknown global '([^']+)'/g;
  let match;
  while ((match = pattern.exec(result.output)) !== null) {
    names.add(match[1]);
  }
  return { names, output: result.output };
}

async function formatLuau(code) {
  return new Promise((resolve, reject) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-"));
    const inputPath = path.join(tmpDir, "Code.luau");
    fs.writeFileSync(inputPath, code, "utf8");

    let stderr = "";
    const child = spawn(PATH_TO_FORMATTER, ["--syntax=Luau", inputPath]);
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    let timedOut = false;
    let killTimer = null;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
    }, TOOL_TIMEOUT_MS);

    child.on("error", (err) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      reject(err.code === "ENOENT" ? missingToolError(PATH_TO_FORMATTER) : err);
    });
    child.on("close", (exitCode) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      try {
        const output = timedOut
          ? "Timed out"
          : exitCode !== 0
            ? stripTempPaths(stderr, tmpDir, inputPath)
            : fs.readFileSync(inputPath, "utf8");
        try {
          fs.unlinkSync(inputPath);
          fs.rmdirSync(tmpDir);
        } catch {}
        resolve({ code: timedOut ? -1 : exitCode, output });
      } catch (err) {
        reject(err);
      }
    });
  });
}

async function compileLuau(code, options) {
  const {
    optimizeLevel,
    debugLevel,
    native,
    remarks,
    binary,
    architecture,
    constants,
  } = options;

  const args = [];

  if (native) {
    args.push("--codegen");
    args.push(`--target=${architecture}`);
  } else if (remarks) {
    args.push("--remarks");
  } else if (binary) {
    args.push("--binary");
  } else if (constants) {
    args.push("--dump-constants");
  }
  args.push(`-g${debugLevel}`);
  args.push(`-O${optimizeLevel}`);
  args.push("--vector-lib=Vector3");
  args.push("--vector-ctor=new");
  args.push("--vector-type=Vector3");

  return await execute(PATH_TO_COMPILER, code, args);
}

module.exports = {
  analyzeLuau,
  generateAST,
  formatLuau,
  compileLuau,
  findUnknownGlobals,
};
