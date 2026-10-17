import {
    DEFAULT_CONFIG_TEMPLATE,
    ensureDefaultConfig,
    readDaemonConfig,
    readDataDir,
    readRouterKey,
    readSettings,
    saveDaemon,
    saveSettings,
    validateSettings,
} from "../../config";

import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

async function directory(): Promise<string>
{
    return mkdtemp(join(tmpdir(), "autonom-config-"));
}

test("launcher settings validate ports, absolute paths, and ignore unknown fields", () =>
{
    assert.deepEqual(validateSettings({ port: 8080, junk: true }), { port: 8080 });
    assert.deepEqual(validateSettings({ configFile: "~/autonom/config.yml" }),
        { configFile: join(homedir(), "autonom/config.yml") });
    assert.throws(() => validateSettings({ port: 70000 }), /between 1 and 65535/);
    assert.throws(() => validateSettings({ port: 8080.5 }), /between 1 and 65535/);
    assert.throws(() => validateSettings({ configFile: "relative/config.yml" }), /absolute path/);
    assert.throws(() => validateSettings([]), /mapping/);
});

test("launcher settings round-trip through YAML", async () =>
{
    const root = await directory();
    try
    {
        const path = join(root, "launcher.yml");
        await saveSettings(path, { port: 9090, configFile: "/tmp/config.yml", commandCenterConfig: "/tmp/center.json" });
        assert.deepEqual(await readSettings(path), {
            port: 9090,
            configFile: "/tmp/config.yml",
            commandCenterConfig: "/tmp/center.json",
        });
        await writeFile(path, "port: [broken\n");
        await assert.rejects(readSettings(path), /invalid YAML/);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("the daemon configuration exposes known fields and a data directory", async () =>
{
    const root = await directory();
    try
    {
        const path = join(root, "config.yml");
        await writeFile(path, `${DEFAULT_CONFIG_TEMPLATE}unknownField: 1\n`);
        assert.deepEqual(await readDaemonConfig(path), {
            dataDir: "~/.local/share/autonom",
            devinCommand: "devin",
            executionTimeout: "30m",
            compactOnResume: false,
            offlineStartAfter: "1h",
            offlineCompactAfter: "1h",
        });
        assert.equal(await readDataDir(path), join(homedir(), ".local/share/autonom"));
        assert.equal(await readRouterKey(path), "");
        assert.deepEqual(await readDaemonConfig(join(root, "missing.yml")), {});
        assert.equal(await readDataDir(join(root, "missing.yml")), root);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("dataDir resolves against the configuration file directory, not the working directory", async () =>
{
    const root = await directory();
    try
    {
        const nested = join(root, "nested");
        await mkdir(nested);
        const path = join(nested, "config.yml");
        await writeFile(path, "dataDir: data\n");
        assert.equal(await readDataDir(path), join(nested, "data"));
        await writeFile(path, "dataDir: /var/lib/autonom\n");
        assert.equal(await readDataDir(path), "/var/lib/autonom");
        await writeFile(path, 'dataDir: "~"\n');
        assert.equal(await readDataDir(path), homedir());
        await writeFile(path, 'dataDir: "~/autonom-data"\n');
        assert.equal(await readDataDir(path), join(homedir(), "autonom-data"));
        await writeFile(path, "devinCommand: devin\n");
        assert.equal(await readDataDir(path), nested);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("daemon settings are validated and written without dropping unrelated keys", async () =>
{
    const root = await directory();
    try
    {
        const path = join(root, "config.yml");
        await ensureDefaultConfig(path);
        await saveDaemon(path, { compactOnResume: true, offlineStartAfter: "30m" });
        const config = await readDaemonConfig(path);
        assert.equal(config.compactOnResume, true);
        assert.equal(config.offlineStartAfter, "30m");
        assert.equal(config.devinCommand, "devin");
        await assert.rejects(saveDaemon(path, { unsupported: "x" }), /Unsupported daemon setting/);
        await assert.rejects(saveDaemon(path, { offlineStartAfter: "0m" }), /Durations must be positive/);
        await assert.rejects(saveDaemon(path, { compactionThresholds: "1,2,3" }), /Unsupported daemon setting/);
        await assert.rejects(saveDaemon(path, { compactOnResume: "yes" }), /must be a boolean/);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});
