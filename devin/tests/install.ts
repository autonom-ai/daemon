import { desktopCommit, desktopMain, desktopVersion } from "../launcher/desktop/build";

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

export const execute = promisify(execFile);
export const repository = resolve(__dirname, "../../../..");
export const installer = join(repository, "devin/install.py");
export const nevra = "devin-desktop-3.10.67-1.el8.x86_64";
export const distro = "f".repeat(64);
export const originalCli = "#!/bin/sh\nprintf 'original CLI\\n'\n";
export const updatedCli = "#!/bin/sh\nprintf 'updated vendor CLI\\n'\n";

const fakeRpm = `#!/usr/bin/env python3
import json, os, sys
manifest = json.load(open(os.environ["FAKE_RPM_DB"]))
args = sys.argv[1:]
if args and args[0] == "-qf":
    entry = manifest["files"].get(args[-1])
    if entry is None:
        sys.exit(1)
    print(entry["nevra"])
    sys.exit(0)
if len(args) >= 2 and args[0] == "-q" and args[1] == "--dump":
    for path, entry in manifest["files"].items():
        print(f"{path} 0 0 {entry['digest']} 0100644 root root {int(entry.get('config', False))} 0 0 X")
    sys.exit(0)
if len(args) >= 2 and args[0] == "-q":
    sys.stdout.write(f"8\\n8:{manifest['distro']}\\n")
    sys.exit(0)
sys.exit(1)
`;

type Fixture = {
    root: string;
    app: string;
    env: NodeJS.ProcessEnv;
    manifestPath: string;
};

export function sha256(content: string | Buffer): string
{
    return createHash("sha256").update(content).digest("hex");
}

export async function fixture(): Promise<Fixture>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-install-"));
    const app = join(root, "resources/app");
    await mkdir(join(app, "out/vs/workbench"), { recursive: true });
    await mkdir(join(root, "bin"));
    await mkdir(join(root, "usr/bin"), { recursive: true });
    await symlink("../../bin/devin-desktop", join(root, "usr/bin/devin-desktop"));
    // Package bytes are a filesystem fixture, not a native UI acceptance surface.
    const files = {
        "package.json": JSON.stringify({ version: desktopVersion, main: desktopMain }),
        "product.json": JSON.stringify({ commit: desktopCommit }),
        "out/main.js": "main bundle",
        "out/vs/workbench/workbench.desktop.main.js": "packaged workbench",
    };
    for (const [file, content] of Object.entries(files))
        await writeFile(join(app, file), content);
    await writeFile(join(root, "devin-desktop"), "#!/bin/sh\nprintf 'original Desktop\\n'\n", { mode: 0o755 });
    await writeFile(join(root, "bin/devin-desktop"), originalCli, { mode: 0o755 });
    const manifestPath = join(root, "rpm-manifest.json");
    await track(manifestPath, app, join(root, "bin/devin-desktop"));
    const binaries = join(root, "fakebin");
    await mkdir(binaries);
    await writeFile(join(binaries, "rpm"), fakeRpm, { mode: 0o755 });
    const env = { ...process.env, PATH: `${binaries}:${process.env.PATH}`, FAKE_RPM_DB: manifestPath,
        // Keep the desktop entry shadowing inside the temporary tree.
        XDG_DATA_HOME: join(root, "user") };
    return { root, app, env, manifestPath };
}

export async function track(manifestPath: string, app: string, cli: string): Promise<void>
{
    const files: Record<string, { digest: string; nevra: string; config?: boolean }> = {};
    for (const file of [
        join(app, "package.json"),
        join(app, "product.json"),
        join(app, "out/main.js"),
        join(app, "out/vs/workbench/workbench.desktop.main.js"),
        cli,
    ])
        files[file] = { digest: sha256(await readFile(file)), nevra: nevra, config: file.endsWith("product.json") };
    await writeFile(manifestPath, JSON.stringify({ distro: distro, files }));
}

export async function packageUpdate(root: string, cli?: string): Promise<void>
{
    const manifestPath = join(root, "rpm-manifest.json");
    const app = join(root, "resources/app");
    await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
    if (cli !== undefined)
        await writeFile(join(root, "bin/devin-desktop"), cli, { mode: 0o755 });
    await track(manifestPath, app, join(root, "bin/devin-desktop"));
}

export async function recordOf(root: string): Promise<Record<string, unknown>>
{
    return JSON.parse(await readFile(join(root, "autonom/install.json"), "utf8")) as Record<string, unknown>;
}
