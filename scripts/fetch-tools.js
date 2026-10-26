#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { execFileSync } = require("child_process");

const ROOT_DIR = path.join(__dirname, "..");
const BIN_DIR = path.join(ROOT_DIR, "bin");
const IS_WINDOWS = process.platform === "win32";
const EXE = IS_WINDOWS ? ".exe" : "";

const args = process.argv.slice(2);
const FORCE = args.includes("--force");
const BUILD = args.includes("--build");

function flag(name, fallback) {
  const i = args.indexOf(name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}

const LUAU_VERSION = flag("--luau-version", "latest");
const STYLUA_VERSION = flag("--stylua-version", "latest");
const LUNE_VERSION = flag("--lune-version", "latest");
const SKIP_LUNE = args.includes("--no-lune");
// Keep the executable and Roblox definition snapshot on the same release.
const LSP_VERSION = flag("--lsp-version", "1.70.1");

function lspAsset() {
  if (process.platform === "win32") return "luau-lsp-win64.zip";
  if (process.platform === "darwin") return "luau-lsp-macos.zip";
  if (process.platform === "linux" && ["x64", "arm64"].includes(process.arch))
    return `luau-lsp-linux-${process.arch === "arm64" ? "arm64" : "x86_64"}.zip`;
  return null;
}

/** The prebuilt StyLua gnu binaries import GLIBC_2.34. */
const MIN_GLIBC = [2, 34];

/** Runtime glibc as [major, minor], or null on musl. */
function glibcVersion() {
  try {
    const v = process.report.getReport().header.glibcVersionRuntime;
    return v ? v.split(".").map(Number) : null;
  } catch {
    return null;
  }
}

/** Musl distros and glibc older than the prebuilt needs both get the static musl build. */
function needsStaticBuild() {
  const v = glibcVersion();
  if (!v) return true; // musl
  return v[0] < MIN_GLIBC[0] || (v[0] === MIN_GLIBC[0] && v[1] < MIN_GLIBC[1]);
}

/** Upstream luau ships x86_64 only, and its Linux build needs glibc >= 2.34. */
function luauAsset() {
  switch (process.platform) {
    case "win32":
      return "luau-windows.zip";
    case "linux":
      return process.arch === "x64" ? "luau-ubuntu.zip" : null;
    case "darwin":
      return "luau-macos.zip";
    default:
      return null;
  }
}

function styluaAsset() {
  const arm = process.arch === "arm64";
  switch (process.platform) {
    case "win32":
      // Upstream ships x86_64 only for Windows; it runs under emulation on arm.
      return "stylua-windows-x86_64.zip";
    case "linux": {
      // Static musl builds also cover glibc < 2.34 (Oracle Linux 8, RHEL 8, Ubuntu 20.04).
      const suffix = needsStaticBuild() ? "-musl" : "";
      return arm
        ? `stylua-linux-aarch64${suffix}.zip`
        : `stylua-linux-x86_64${suffix}.zip`;
    }
    case "darwin":
      return arm ? "stylua-macos-aarch64.zip" : "stylua-macos-x86_64.zip";
    default:
      return null;
  }
}

// Lune's asset name embeds the version, so the tag is resolved first.
function luneAsset(version) {
  const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
  const osName = {
    win32: "windows",
    linux: "linux",
    darwin: "macos",
  }[process.platform];
  if (!osName) return null;
  return `lune-${version.replace(/^v/, "")}-${osName}-${arch}.zip`;
}

function releaseUrl(repo, version, asset) {
  return version === "latest"
    ? `https://github.com/${repo}/releases/latest/download/${asset}`
    : `https://github.com/${repo}/releases/download/${version}/${asset}`;
}

async function download(url) {
  const res = await fetch(url, { redirect: "follow" });
  if (!res.ok) {
    throw new Error(`GET ${url} -> ${res.status} ${res.statusText}`);
  }
  return Buffer.from(await res.arrayBuffer());
}

/**
 * Minimal zip reader, stored (0) and deflate (8) only. In-process because GNU tar can't read zips.
 * @param {Buffer} buf
 * @returns {Map<string, Buffer>} entry name -> contents
 */
function readZip(buf) {
  const EOCD_SIG = 0x06054b50;
  const CEN_SIG = 0x02014b50;

  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 22 - 0xffff; i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG) {
      eocd = i;
      break;
    }
  }
  if (eocd === -1)
    throw new Error("Not a zip file (no end-of-central-directory)");

  const entryCount = buf.readUInt16LE(eocd + 10);
  let ptr = buf.readUInt32LE(eocd + 16);

  const out = new Map();
  for (let n = 0; n < entryCount; n++) {
    if (buf.readUInt32LE(ptr) !== CEN_SIG) {
      throw new Error("Corrupt zip central directory");
    }
    const method = buf.readUInt16LE(ptr + 10);
    const compressedSize = buf.readUInt32LE(ptr + 20);
    const nameLen = buf.readUInt16LE(ptr + 28);
    const extraLen = buf.readUInt16LE(ptr + 30);
    const commentLen = buf.readUInt16LE(ptr + 32);
    const localOffset = buf.readUInt32LE(ptr + 42);
    const name = buf.toString("utf8", ptr + 46, ptr + 46 + nameLen);

    // The local header repeats the name/extra with its own lengths.
    const localNameLen = buf.readUInt16LE(localOffset + 26);
    const localExtraLen = buf.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    const data = buf.subarray(dataStart, dataStart + compressedSize);

    if (!name.endsWith("/")) {
      out.set(
        name,
        method === 0 ? Buffer.from(data) : zlib.inflateRawSync(data),
      );
    }

    ptr += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

async function install(label, url, wanted) {
  console.log(`Downloading ${label} from ${url}`);
  fs.mkdirSync(BIN_DIR, { recursive: true });
  const zip = readZip(await download(url));

  for (const name of wanted) {
    // Archives are flat today, but tolerate a leading directory.
    const key =
      [...zip.keys()].find((k) => k === name || k.endsWith("/" + name)) || null;
    if (!key) {
      throw new Error(
        `${label}: ${name} not found in archive (has: ${[...zip.keys()].join(", ")})`,
      );
    }
    const dest = path.join(BIN_DIR, name);
    fs.writeFileSync(dest, zip.get(key));
    if (!IS_WINDOWS) fs.chmodSync(dest, 0o755);
    console.log(
      `  wrote ${name} (${(zip.get(key).length / 1024 / 1024).toFixed(1)} MB)`,
    );
  }
}

const LUAU_CMAKE_TARGETS = {
  "Luau.Compile.CLI": "luau-compile",
  "Luau.Analyze.CLI": "luau-analyze",
  "Luau.Ast.CLI": "luau-ast",
};

function haveCommand(cmd) {
  try {
    execFileSync(cmd, ["--version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/** Build the luau CLI from the release tarball, for aarch64 Linux which has no prebuilt. */
async function buildLuauFromSource(version) {
  for (const cmd of ["cmake", "tar"]) {
    if (!haveCommand(cmd)) {
      throw new Error(
        `${cmd} is required to build luau from source. Install it (e.g. ` +
          "`sudo apt install cmake build-essential`) and re-run.",
      );
    }
  }

  const tag =
    version === "latest" ? await latestTag("luau-lang/luau") : version;
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "luau-build-"));
  const tarball = path.join(workDir, "luau.tar.gz");

  console.log(`Building luau ${tag} from source (no prebuilt aarch64 binary)`);
  console.log("  downloading source...");
  fs.writeFileSync(
    tarball,
    await download(
      `https://github.com/luau-lang/luau/archive/refs/tags/${tag}.tar.gz`,
    ),
  );

  execFileSync("tar", ["-xzf", tarball, "-C", workDir], { stdio: "inherit" });
  const srcDir = path.join(workDir, `luau-${tag}`);
  if (!fs.existsSync(srcDir)) {
    throw new Error(`Unexpected source layout: ${srcDir} missing`);
  }

  const buildDir = path.join(srcDir, "cmake");
  fs.mkdirSync(buildDir, { recursive: true });

  console.log("  configuring...");
  execFileSync("cmake", ["..", "-DCMAKE_BUILD_TYPE=Release"], {
    cwd: buildDir,
    stdio: "inherit",
  });

  console.log("  compiling (this takes a few minutes)...");
  execFileSync(
    "cmake",
    [
      "--build",
      ".",
      "--target",
      ...Object.keys(LUAU_CMAKE_TARGETS),
      "--config",
      "Release",
      "-j",
      String(os.cpus().length),
    ],
    { cwd: buildDir, stdio: "inherit" },
  );

  fs.mkdirSync(BIN_DIR, { recursive: true });
  for (const binName of Object.values(LUAU_CMAKE_TARGETS)) {
    // CMake may place output in the build dir or a Release/ subdir.
    const candidates = [
      path.join(buildDir, binName),
      path.join(buildDir, "Release", binName),
    ];
    const built = candidates.find((c) => fs.existsSync(c));
    if (!built) {
      throw new Error(`Build finished but ${binName} was not found`);
    }
    const dest = path.join(BIN_DIR, binName);
    fs.copyFileSync(built, dest);
    fs.chmodSync(dest, 0o755);
    console.log(`  installed ${binName}`);
  }

  fs.rmSync(workDir, { recursive: true, force: true });
}

async function latestTag(repo) {
  const res = await fetch(
    `https://api.github.com/repos/${repo}/releases/latest`,
  );
  if (!res.ok) throw new Error(`Cannot resolve latest tag for ${repo}`);
  return (await res.json()).tag_name;
}

function verify(name, versionArg) {
  const p = path.join(BIN_DIR, name);
  if (!fs.existsSync(p)) return `${name}: MISSING`;
  try {
    const out = execFileSync(p, [versionArg], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return `${name}: ${out.trim().split("\n")[0]}`;
  } catch (err) {
    // luau-ast has no --version flag; existing + executable is enough.
    return `${name}: present (no version output)`;
  }
}

async function main() {
  const luauZip = luauAsset();
  const styluaZip = styluaAsset();
  // No usable prebuilt: aarch64 has no asset, and the x86_64 one needs glibc 2.34+.
  const buildLuau =
    BUILD || (process.platform === "linux" && (!luauZip || needsStaticBuild()));

  if (!styluaZip || (!luauZip && !buildLuau)) {
    console.error(`Unsupported platform: ${process.platform}/${process.arch}.`);
    console.error(
      "Download the binaries manually from the luau-lang/luau and JohnnyMorganz/StyLua releases.",
    );
    process.exit(1);
  }

  const luauBins = [
    `luau-compile${EXE}`,
    `luau-analyze${EXE}`,
    `luau-ast${EXE}`,
  ];
  const styluaBins = [`stylua${EXE}`];
  const luneBins = [`lune${EXE}`];

  const missing = (names) =>
    names.filter((n) => !fs.existsSync(path.join(BIN_DIR, n)));

  try {
    // Only analysis needs luau-lsp, so its failure mustn't stop the other tools.
    try {
      const lspVersion = LSP_VERSION === "latest" ? await latestTag("JohnnyMorganz/luau-lsp") : LSP_VERSION;
      const lspZip = lspAsset();
      const lspBins = [`luau-lsp${EXE}`];
      if (!lspZip) throw new Error(`No luau-lsp build for ${process.platform}/${process.arch}`);
      if (FORCE || missing(lspBins).length) {
        await install("luau-lsp", releaseUrl("JohnnyMorganz/luau-lsp", lspVersion, lspZip), lspBins);
      }
      const definitions = path.join(BIN_DIR, "robloxTypes.d.luau");
      if (FORCE || !fs.existsSync(definitions)) {
        const data = await download(`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${lspVersion}/scripts/globalTypes.d.lua`);
        fs.writeFileSync(definitions, data);
        console.log(`  wrote Roblox type definitions from luau-lsp ${lspVersion}`);
      }
    } catch (err) {
      console.warn(`luau-lsp install failed, analysis will be unavailable: ${err.message}`);
    }
    if (FORCE || missing(luauBins).length) {
      if (buildLuau) {
        await buildLuauFromSource(LUAU_VERSION);
      } else {
        await install(
          "luau",
          releaseUrl("luau-lang/luau", LUAU_VERSION, luauZip),
          luauBins,
        );
      }
    } else {
      console.log(
        "luau tools already present, skipping (use --force to refetch)",
      );
    }

    if (FORCE || missing(styluaBins).length) {
      await install(
        "StyLua",
        releaseUrl("JohnnyMorganz/StyLua", STYLUA_VERSION, styluaZip),
        styluaBins,
      );
    } else {
      console.log("stylua already present, skipping (use --force to refetch)");
    }

    // Lune is only for ENABLE_LOCAL_EXEC; --no-lune skips it on Roblox-only hosts.
    if (!SKIP_LUNE && (FORCE || missing(luneBins).length)) {
      const luneVersion =
        LUNE_VERSION === "latest"
          ? await latestTag("lune-org/lune")
          : LUNE_VERSION;
      const luneZip = luneAsset(luneVersion);
      if (!luneZip) {
        console.warn(
          `Skipping lune: no prebuilt for ${process.platform}/${process.arch}.`,
        );
      } else {
        await install(
          "lune",
          releaseUrl("lune-org/lune", luneVersion, luneZip),
          luneBins,
        );
      }
    } else if (!SKIP_LUNE) {
      console.log("lune already present, skipping (use --force to refetch)");
    }
  } catch (err) {
    console.error(`\nFailed: ${err.message}`);
    // Don't fail npm install from postinstall; startup reports missing tools.
    if (process.env.npm_lifecycle_event === "postinstall") {
      console.error(
        "Continuing anyway. Run `npm run fetch-tools` once you have network access.",
      );
      return;
    }
    process.exit(1);
  }

  console.log(`\nInstalled for ${process.platform}/${process.arch}:`);
  for (const line of [
    verify(`luau-compile${EXE}`, "--version"),
    verify(`luau-analyze${EXE}`, "--version"),
    verify(`luau-lsp${EXE}`, "--version"),
    verify(`luau-ast${EXE}`, "--help"),
    verify(`stylua${EXE}`, "--version"),
    ...(SKIP_LUNE ? [] : [verify(`lune${EXE}`, "--version")]),
  ]) {
    console.log("  " + line);
  }
}

main();
