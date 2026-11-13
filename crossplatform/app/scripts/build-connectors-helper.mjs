// Builds the connector hub's helper (crates/theo-connectors) and puts it where Tauri's `externalBin` looks for it:
// src-tauri/binaries/theo-connectors-<target triple>[.exe]. Tauri then ships it beside the app in every installer (and copies
// it beside the app in target/<profile> for a plain build), where the engine finds it (theo-core/src/hub.rs, helper_path).
// Runs before `tauri build` and `tauri dev` (tauri.conf.json). `--debug` builds the debug helper; a release build of the
// app gets a release helper.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const appFolder = join(dirname(fileURLToPath(import.meta.url)), "..");
const workspaceFolder = join(appFolder, "..");
const isDebugBuild = process.argv.includes("--debug");

// Tauri tells its before-commands which target it builds for; on its own, this is the host's.
const targetTriple = process.env.TAURI_ENV_TARGET_TRIPLE
  || execFileSync("rustc", ["-vV"], { encoding: "utf8" }).split("\n").find((line) => line.startsWith("host:")).slice("host:".length).trim();
const executableSuffix = targetTriple.includes("windows") ? ".exe" : "";

const cargoArguments = ["build", "-p", "theo-connectors", "--target", targetTriple];
if (!isDebugBuild) cargoArguments.push("--release");
execFileSync("cargo", cargoArguments, { cwd: workspaceFolder, stdio: "inherit" });

const builtHelper = join(workspaceFolder, "target", targetTriple, isDebugBuild ? "debug" : "release", `theo-connectors${executableSuffix}`);
const sidecarFolder = join(appFolder, "src-tauri", "binaries");
const sidecarFile = join(sidecarFolder, `theo-connectors-${targetTriple}${executableSuffix}`);
mkdirSync(sidecarFolder, { recursive: true });
copyFileSync(builtHelper, sidecarFile);
if (!executableSuffix) chmodSync(sidecarFile, 0o755);
console.log(`connector helper ready: ${sidecarFile}`);
