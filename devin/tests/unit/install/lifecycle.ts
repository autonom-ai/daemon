import { resolveDesktopBinary } from "../../../launcher/desktop/process";
import {
    execute,
    fixture,
    installer,
    originalCli,
    recordOf,
    repository,
    sha256
} from "../../install";

import assert from "node:assert/strict";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";

test("installation replaces the CLI entrypoint, keeps app bundles pristine, and rolls back byte-for-byte", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const paths = ["package.json", "product.json", "out/main.js", "out/vs/workbench/workbench.desktop.main.js"];
        const originals = await Promise.all(paths.map((file) => readFile(join(app, file))));
        const cli = await readFile(join(root, "bin/devin-desktop"));
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")), cli);
        const stub = await readFile(join(root, "bin/devin-desktop"));
        assert.match(stub.toString(), /exec .*dist\/launcher.js.* "\$@"/);
        assert.equal(resolveDesktopBinary(join(root, "bin/devin-desktop")), join(root, "devin-desktop"));
        for (const file of ["dist/launcher.js", "dist/runtime.js", "assets/ui.yml",
            "devin/launcher/cdp/control.mjs", "source/daemon/interop/devin/hook.py", "source/mcp/server.py", "source/mcp/daemon.py", "source/mcp/coord.py", "source/mcp/tools.py",
            "devin/hooks.v1.json", "bin/autonom-daemon", "bin/autonom-acp"])
            assert.deepEqual(await readFile(join(root, "autonom", file)), await readFile(join(repository, file)));
        await assert.rejects(readFile(join(root, "autonom/source/mcp/orchestrate.py")), { code: "ENOENT" });
        const saved = await recordOf(root);
        assert.equal(saved.version, 2);
        assert.equal((saved.build as Record<string, unknown>).source, "package");
        assert.equal((saved.cli as Record<string, unknown>).originalHash, sha256(cli));

        await execute("python3", [installer, "--no-build", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.match((await execute("python3", [installer, "--check", "--app", app], { env })).stdout, /launcher installed/);
        await execute("python3", [installer, "--uninstall", "--app", app], { env });
        await execute("python3", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), cli);
        for (let index = 0; index < paths.length; index++)
            assert.deepEqual(await readFile(join(app, paths[index]!)), originals[index]);

        await execute("python3", [installer, "--no-build", "--app", app], { env });
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
        await execute("python3", [installer, "--no-build", "--app", join(root, "resources/app")], { env });
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
        await execute("python3", [installer, "--no-build", "--app", app], { env });
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
        await writeFile(join(root, "bin/devin-desktop.autonom.orig"), originalCli);
        await writeFile(join(root, "autonom/install.json"),
            `${JSON.stringify({ originalHash: "c".repeat(64), stubHash: "b".repeat(64) })}\n`);
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /backup changed externally|does not match/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(originalCli));
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});
