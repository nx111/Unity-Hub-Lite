import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { spawnSync } from "node:child_process";

const cargoHome = process.env.CARGO_HOME || join(homedir(), ".cargo");
const cargoBin = join(cargoHome, "bin");

// npm processes inherit the terminal environment. A terminal opened before
// rustup was installed may not contain ~/.cargo/bin, so make the standard
// Rust installation discoverable for Tauri without requiring a restart.
if (existsSync(join(cargoBin, process.platform === "win32" ? "cargo.exe" : "cargo"))) {
  const pathEntries = (process.env.PATH || "").split(delimiter);
  if (!pathEntries.some((entry) => entry.toLowerCase() === cargoBin.toLowerCase())) {
    process.env.PATH = [cargoBin, ...pathEntries].filter(Boolean).join(delimiter);
  }
}

const cargoCommand = process.platform === "win32" ? "where.exe" : "which";
const cargoCheck = spawnSync(cargoCommand, ["cargo"], { encoding: "utf8" });
if (cargoCheck.status !== 0) {
  console.error("Rust Cargo was not found. Install Rust with rustup, then open a new terminal and run this command again.");
  process.exit(cargoCheck.status || 1);
}

const rustcCheck = spawnSync("rustc", ["--version", "--verbose"], { encoding: "utf8" });
if (rustcCheck.status !== 0 || !/^host:/m.test(rustcCheck.stdout || "")) {
  const details = (rustcCheck.stderr || rustcCheck.stdout || "").trim();
  console.error("Rust rustc is not ready. Repair the default toolchain with `rustup toolchain install stable --profile minimal`, then run this command again.");
  if (details) console.error(details);
  process.exit(rustcCheck.status || 1);
}

const tauriCli = join(process.cwd(), "node_modules", "@tauri-apps", "cli", "tauri.js");
const result = spawnSync(process.execPath, [tauriCli, ...process.argv.slice(2)], {
  cwd: process.cwd(),
  env: process.env,
  stdio: "inherit",
});

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 1);
