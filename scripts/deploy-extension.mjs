#!/usr/bin/env node
// Build the Autonom extension and deploy it into the installed Devin Desktop extension
// directory, verifying every deployed file hash. Reload the window afterwards so the
// extension host activates the new build (the patch and companion deploy on activation).
//
//   node scripts/deploy-extension.mjs

import { execSync } from "node:child_process";
import { cp, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const extensionDir = join(repoRoot, "extension");
const installDir = process.env.AUTONOM_EXTENSION_DIR || join(homedir(), ".devin", "extensions", "cet.autonom-0.4.0");

const sha256 = (buffer) => createHash("sha256").update(buffer).digest("hex");

console.log(`Building ${extensionDir} ...`);
execSync("npm run build", { cwd: extensionDir, stdio: "inherit" });

console.log(`Deploying to ${installDir} ...`);
for (const name of ["dist", "media"]) {
    await cp(join(extensionDir, name), join(installDir, name), { recursive: true });
}
await cp(join(extensionDir, "package.json"), join(installDir, "package.json"));

const deployed = [
    "dist/extension.js",
    "dist/commandCenter/autonom.bundle.js",
    "dist/commandCenter/autonom.sessions.css",
    "package.json",
];
let failed = false;
for (const relative of deployed) {
    const source = sha256(await readFile(join(extensionDir, relative)));
    const destination = sha256(await readFile(join(installDir, relative)));
    if (source !== destination) {
        failed = true;
        console.error(`MISMATCH: ${relative} (${source} != ${destination})`);
    } else {
        console.log(`verified ${relative} ${source.slice(0, 16)}`);
    }
}
if (failed) {
    console.error("deploy-extension: FAILED");
    process.exit(1);
}
console.log("deploy-extension: OK — reload the Devin Desktop window to activate");
