import { copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const version = "0.1.0";
const executable = join(root, "src-tauri", "target", "release", "unity-hub-lite.exe");
const outputDir = join(root, "src-tauri", "target", "release", "bundle", "portable");
const stagingDir = join(outputDir, "Unity Hub Lite");
const archive = join(outputDir, `Unity Hub Lite_${version}_x64_portable.zip`);

if (process.platform !== "win32") {
  console.error("Portable packaging currently supports Windows only.");
  process.exit(1);
}

if (!existsSync(executable)) {
  console.error("Release executable not found. Run `npm run tauri build` first.");
  process.exit(1);
}

mkdirSync(outputDir, { recursive: true });
rmSync(stagingDir, { recursive: true, force: true });
rmSync(archive, { force: true });
mkdirSync(stagingDir, { recursive: true });
copyFileSync(executable, join(stagingDir, "Unity Hub Lite.exe"));
writeFileSync(
  join(stagingDir, "README-Portable.txt"),
  "Unity Hub Lite (portable)\r\n\r\nDouble-click `Unity Hub Lite.exe` to run. No installation is required.\r\n\r\nThe application uses the current user's Unity cache directory for downloaded packages.\r\n",
  "utf8",
);

const powershell = [
  "$ErrorActionPreference = 'Stop'",
  `$source = '${stagingDir.replaceAll("'", "''")}'`,
  `$destination = '${archive.replaceAll("'", "''")}'`,
  "Add-Type -AssemblyName System.IO.Compression.FileSystem",
  "[System.IO.Compression.ZipFile]::CreateFromDirectory($source, $destination, [System.IO.Compression.CompressionLevel]::Optimal, $false)",
].join("; ");
const result = spawnSync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", powershell], {
  stdio: "inherit",
});

if (result.status !== 0) process.exit(result.status || 1);
console.log(`Created portable archive: ${archive}`);
