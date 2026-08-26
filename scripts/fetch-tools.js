#!/usr/bin/env node
/**
 * Download the luau CLI tools, StyLua and Lune from their upstream GitHub
 * releases into bin/, where src/config.js expects to find them.
 *
 * Usage:
 *   node scripts/fetch-tools.js            # fetch anything missing
 *   node scripts/fetch-tools.js --force    # re-download even if present
 *   node scripts/fetch-tools.js --build    # compile luau from source (aarch64)
 *   node scripts/fetch-tools.js --no-lune    # skip the local-sandbox runtime
 *   node scripts/fetch-tools.js --luau-version 0.735 --stylua-version v2.5.2
 *
 * Archives are unpacked in-process: GNU tar (Linux) cannot read zip files, so
 * shelling out to tar/unzip would work on Windows and fail on Linux.
 */
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

/**
 * True on musl distros (Alpine) or where glibc is too old for the prebuilt
 * gnu binaries — in both cases the statically linked musl build is the one
 * that will actually run.
 */
function needsStaticBuild() {
  const v = glibcVersion();
  if (!v) return true; // musl
  return v[0] < MIN_GLIBC[0] || (v[0] === MIN_GLIBC[0] && v[1] < MIN_GLIBC[1]);
}

/**
 * Which release archive to pull for this platform.
 *
 * Upstream luau publishes x86_64 builds only — there is no aarch64 Linux
 * asset — and the Linux build needs glibc >= 2.34, so it will not run on
 * Ubuntu 20.04, Debian 11, RHEL 8, or Alpine.
 */
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
      // The musl builds are statically linked, so they also cover distros
      // whose glibc predates 2.34 (Oracle Linux 8, RHEL 8, Ubuntu 20.04).
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

// Lune ships prebuilt for every platform this bot targets, aarch64 Linux
// included, so unlike luau there is never a source build to fall back to.
// The asset name embeds the version, so the tag has to be resolved first.
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
 * Minimal zip reader: walks the central directory and inflates the entries we
 * want. Handles stored (0) and deflate (8), which is all these archives use.
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

/** Pull `wanted` out of the archive at `url` and write them into the root. */
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

/** The three luau CLI targets, as CMake target name -> produced binary. */
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

/**
 * Build the luau CLI tools from source.
 *
 * Needed on aarch64 Linux, where upstream publishes no prebuilt binary. Uses
 * the release source tarball rather than git, and hands the .tar.gz to system
 * tar — unlike zip, every tar handles gzip.
 */
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

/** Ask a freshly installed binary for its version, as a smoke test. */
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
  // Build luau from source when no prebuilt applies: aarch64 has no asset at
  // all, and the x86_64 asset needs glibc 2.34+, so on an older distro the
  // download would install something that cannot run.
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

    // Only needed for the local Lune sandbox (ENABLE_LOCAL_EXEC). Skippable so
    // a Roblox-only deployment does not pull a binary it never runs.
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
    // Running as an npm postinstall hook: a download failure must not fail the
    // whole install. Missing tools are reported clearly at bot startup instead.
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
    verify(`luau-ast${EXE}`, "--help"),
    verify(`stylua${EXE}`, "--version"),
    ...(SKIP_LUNE ? [] : [verify(`lune${EXE}`, "--version")]),
  ]) {
    console.log("  " + line);
  }
}

main();
