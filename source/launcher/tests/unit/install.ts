import { resolveDesktopBinary } from "../../desktop";

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile }
    from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const execute = promisify(execFile);
const repository = resolve(__dirname, "../../..");
const installer = join(repository, "install.sh");
const installedApp = "/usr/share/devin-desktop/resources/app";
const NEVRA = "devin-desktop-3.10.67-1.el8.x86_64";
const DISTRO = "f".repeat(64);
const ORIGINAL_CLI = "#!/bin/sh\nprintf 'original CLI\\n'\n";
const UPDATED_CLI = "#!/bin/sh\nprintf 'updated vendor CLI\\n'\n";

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

function sha256(content: string | Buffer): string
{
    return createHash("sha256").update(content).digest("hex");
}

async function fixture(): Promise<Fixture>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-install-"));
    const app = join(root, "resources/app");
    await mkdir(join(app, "out/vs/workbench"), { recursive: true });
    await mkdir(join(root, "bin"));
    await mkdir(join(root, "usr/bin"), { recursive: true });
    await symlink("../../bin/devin-desktop", join(root, "usr/bin/devin-desktop"));
    for (const file of ["package.json", "product.json", "out/main.js", "out/vs/workbench/workbench.desktop.main.js"])
        await copyFile(join(installedApp, file), join(app, file));
    await writeFile(join(root, "devin-desktop"), "#!/bin/sh\nprintf 'original Desktop\\n'\n", { mode: 0o755 });
    await writeFile(join(root, "bin/devin-desktop"), ORIGINAL_CLI, { mode: 0o755 });
    const manifestPath = join(root, "rpm-manifest.json");
    await track(manifestPath, app, join(root, "bin/devin-desktop"));
    const binaries = join(root, "fakebin");
    await mkdir(binaries);
    await writeFile(join(binaries, "rpm"), fakeRpm, { mode: 0o755 });
    const env = { ...process.env, PATH: `${binaries}:${process.env.PATH}`, FAKE_RPM_DB: manifestPath };
    return { root, app, env, manifestPath };
}

async function track(manifestPath: string, app: string, cli: string): Promise<void>
{
    const files: Record<string, { digest: string; nevra: string; config?: boolean }> = {};
    for (const file of [
        join(app, "package.json"),
        join(app, "product.json"),
        join(app, "out/main.js"),
        join(app, "out/vs/workbench/workbench.desktop.main.js"),
        cli,
    ])
        files[file] = { digest: sha256(await readFile(file)), nevra: NEVRA, config: file.endsWith("product.json") };
    await writeFile(manifestPath, JSON.stringify({ distro: DISTRO, files }));
}

async function packageUpdate(root: string, cli?: string): Promise<void>
{
    const manifestPath = join(root, "rpm-manifest.json");
    const app = join(root, "resources/app");
    await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
    if (cli !== undefined)
        await writeFile(join(root, "bin/devin-desktop"), cli, { mode: 0o755 });
    await track(manifestPath, app, join(root, "bin/devin-desktop"));
}

async function recordOf(root: string): Promise<Record<string, unknown>>
{
    return JSON.parse(await readFile(join(root, "autonom/install.json"), "utf8")) as Record<string, unknown>;
}

test("installation replaces the CLI entrypoint, keeps app bundles pristine, and rolls back byte-for-byte", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const paths = ["package.json", "product.json", "out/main.js", "out/vs/workbench/workbench.desktop.main.js"];
        const originals = await Promise.all(paths.map((file) => readFile(join(app, file))));
        const cli = await readFile(join(root, "bin/devin-desktop"));
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")), cli);
        const stub = await readFile(join(root, "bin/devin-desktop"));
        assert.match(stub.toString(), /exec .*dist\/launcher.js.* "\$@"/);
        assert.equal(resolveDesktopBinary(join(root, "bin/devin-desktop")), join(root, "devin-desktop"));
        for (const file of ["dist/launcher.js", "dist/runtime.js", "assets/ui.yml",
            "source/launcher/cdp.mjs", "source/daemon/interop/devin/hook.py", "source/mcp/server.py",
            "templates/hooks.v1.json", "bin/autonom-daemon", "bin/autonom-acp"])
            assert.deepEqual(await readFile(join(root, "autonom", file)), await readFile(join(repository, file)));
        await assert.rejects(readFile(join(root, "autonom/source/mcp/orchestrate.py")), { code: "ENOENT" });
        const saved = await recordOf(root);
        assert.equal(saved.version, 2);
        assert.equal((saved.build as Record<string, unknown>).source, "package");
        assert.equal((saved.cli as Record<string, unknown>).originalHash, sha256(cli));

        await execute("bash", [installer, "--no-build", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.match((await execute("bash", [installer, "--check", "--app", app], { env })).stdout, /launcher installed/);
        await execute("bash", [installer, "--uninstall", "--app", app], { env });
        await execute("bash", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), cli);
        for (let index = 0; index < paths.length; index++)
            assert.deepEqual(await readFile(join(app, paths[index]!)), originals[index]);

        await execute("bash", [installer, "--no-build", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installed entrypoints preserve argv, cwd, stdout, stderr, and exit status like direct Node", async () =>
{
    const { root, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", join(root, "resources/app")], { env });
        const launcher = join(root, "autonom/dist/launcher.js");
        await writeFile(launcher, "console.log(JSON.stringify({arguments:process.argv.slice(2),cwd:process.cwd()}));"
            + "console.error('launcher stderr');process.exitCode=7;\n");
        const arguments_ = ["--debug=9333", "workspace with spaces", "--new-window", "--help"];
        const direct = await execute(process.execPath, [launcher, ...arguments_], { cwd: root })
            .catch((error: { stdout: string; stderr: string; code: number }) => error);
        for (const entrypoint of ["bin/devin-desktop", "usr/bin/devin-desktop"])
        {
            const installed = await execute(join(root, entrypoint), arguments_, { cwd: root })
                .catch((error: { stdout: string; stderr: string; code: number }) => error);
            assert.equal(installed.stdout, direct.stdout);
            assert.equal(installed.stderr, direct.stderr);
            assert.equal("code" in installed && installed.code, 7);
        }
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a legacy record migrates only when it matches the current CLI", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const cli = await readFile(join(root, "bin/devin-desktop"));
        const legacy = { originalHash: sha256(cli), stubHash: "b".repeat(64) };
        await mkdir(join(root, "autonom"), { recursive: true });
        await writeFile(join(root, "bin/devin-desktop.autonom.orig"), cli);
        await writeFile(join(root, "autonom/install.json"), `${JSON.stringify(legacy)}\n`);
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const saved = await recordOf(root);
        assert.equal(saved.version, 2);
        assert.equal((saved.cli as Record<string, unknown>).originalHash, sha256(cli));
        const archives = await readdir(join(root, "autonom/tracked-builds"));
        assert.equal(archives.length, 1);
        assert.deepEqual(JSON.parse(await readFile(join(root, "autonom/tracked-builds", archives[0]!, "install.json"), "utf8")), legacy);
        assert.deepEqual(await readFile(join(root, "autonom/tracked-builds", archives[0]!, "devin-desktop.orig")), cli);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a mismatched legacy record refuses to migrate", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await mkdir(join(root, "autonom"), { recursive: true });
        await writeFile(join(root, "bin/devin-desktop.autonom.orig"), ORIGINAL_CLI);
        await writeFile(join(root, "autonom/install.json"),
            `${JSON.stringify({ originalHash: "c".repeat(64), stubHash: "b".repeat(64) })}\n`);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /backup changed externally|does not match/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(ORIGINAL_CLI));
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("an official package update refreshes the tracked generation and archives the previous one", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const cli = await readFile(join(root, "bin/devin-desktop"));
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const first = await recordOf(root);
        await packageUpdate(root, UPDATED_CLI);
        assert.match((await execute("bash", [installer, "--check", "--app", app], { env })).stdout,
            /official Desktop update|reinstall/);
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const saved = await recordOf(root);
        assert.equal(saved.version, 2);
        assert.equal((saved.cli as Record<string, unknown>).originalHash, sha256(UPDATED_CLI));
        assert.notDeepEqual(saved.build, first.build);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")), Buffer.from(UPDATED_CLI));
        const archives = await readdir(join(root, "autonom/tracked-builds"));
        assert.equal(archives.length, 1);
        assert.deepEqual(await readFile(join(root, "autonom/tracked-builds", archives[0]!, "devin-desktop.orig")), cli);
        assert.match(await readFile(join(root, "bin/devin-desktop"), "utf8"), /launcher\.js/);
        await execute("bash", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(UPDATED_CLI));
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a package update reverted to the vendor CLI reports pristine without touching files", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        await writeFile(join(root, "bin/devin-desktop"), ORIGINAL_CLI, { mode: 0o755 });
        const out = await execute("bash", [installer, "--check", "--app", app], { env });
        assert.match(out.stdout, /verified against package|verified pin/);
        assert.match(out.stdout, /vendor Devin Desktop CLI|wrapper is not active|reinstall/);
        const before = await readFile(join(root, "bin/devin-desktop"));
        await execute("bash", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), before);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("uninstall refuses to restore a stale-generation CLI backup", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const manifestPath = join(root, "rpm-manifest.json");
        await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
        await track(manifestPath, app, join(root, "bin/devin-desktop"));
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(UPDATED_CLI);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app", app], { env }),
            /previous Desktop build/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a retained wrapper over a new package refuses to reinstall with a stale backup", async () =>
{
    const { root, app, env, manifestPath } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
        await track(manifestPath, app, join(root, "bin/devin-desktop"));
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(UPDATED_CLI);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /packaged CLI|cannot be proven/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")),
            Buffer.from(ORIGINAL_CLI));
        assert.deepEqual(await recordOf(root), record);
        await assert.rejects(readdir(join(root, "autonom/tracked-builds")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a newer package with the same workbench refuses the stale-generation backup", async () =>
{
    const { root, env, manifestPath } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", join(root, "resources/app")], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.distro = "e".repeat(64);
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(UPDATED_CLI);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("bash", [installer, "--no-build", "--app",
            join(root, "resources/app")], { env }), /packaged CLI|cannot be proven/);
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app",
            join(root, "resources/app")], { env }), /previous Desktop build|cannot be proven/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await recordOf(root), record);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a missing recorded backup refuses install and uninstall before any mutation", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        await rm(join(root, "bin/devin-desktop.autonom.orig"));
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /backup is missing/);
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app", app], { env }),
            /backup is missing/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await recordOf(root), record);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a symlinked install target refuses without writing outside it", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const outside = join(root, "outside");
        await mkdir(outside);
        await mkdir(join(root, "autonom"), { recursive: true });
        await symlink(outside, join(root, "autonom/bin"));
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /symlinked path/);
        assert.deepEqual(await readdir(outside), []);
        assert.deepEqual(await readdir(join(root, "autonom")), ["bin"]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(ORIGINAL_CLI));
        await assert.rejects(readFile(join(root, "autonom/install.json")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a late record write failure restores the CLI, backup, record, and payload", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const record = await recordOf(root);
        await packageUpdate(root, UPDATED_CLI);
        await mkdir(join(root, "autonom/tracked-builds"), { recursive: true });
        await chmod(join(root, "autonom"), 0o555);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /read-only|Installation failed/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(UPDATED_CLI));
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")),
            Buffer.from(ORIGINAL_CLI));
        assert.deepEqual(await recordOf(root), record);
        assert.deepEqual(await readdir(join(root, "autonom/tracked-builds")), []);
        assert.deepEqual(await readFile(join(root, "autonom/dist/launcher.js")),
            await readFile(join(repository, "dist/launcher.js")));
        await chmod(join(root, "autonom"), 0o755);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a failed payload write leaves the CLI and record untouched", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await mkdir(join(root, "autonom"), { recursive: true });
        await writeFile(join(root, "autonom/dist"), "not a directory");
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }),
            /Installation failed|read-only/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(ORIGINAL_CLI));
        await assert.rejects(readFile(join(root, "bin/devin-desktop.autonom.orig")), { code: "ENOENT" });
        await assert.rejects(readFile(join(root, "autonom/install.json")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer rejects external entrypoint edits rather than overwriting them", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app], { env });
        const entrypoint = join(root, "bin/devin-desktop");
        const changed = `${await readFile(entrypoint, "utf8")}\n`;
        await writeFile(entrypoint, changed);
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app", app], { env }), /changed outside Autonom/);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }), /changed outside Autonom/);
        assert.equal(await readFile(entrypoint, "utf8"), changed);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer refuses unsupported Desktop builds without creating a backup", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const packagePath = join(app, "package.json");
        const metadata = JSON.parse(await readFile(packagePath, "utf8"));
        metadata.version = "0.0.0";
        const changed = JSON.stringify(metadata);
        await writeFile(packagePath, changed);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app], { env }), /Unsupported Devin Desktop build/);
        assert.equal(await readFile(packagePath, "utf8"), changed);
        await assert.rejects(readFile(join(root, "bin/devin-desktop.autonom.orig")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});
