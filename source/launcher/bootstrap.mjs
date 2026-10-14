import { app } from "electron";
import { spawn } from "node:child_process";
import { closeSync, constants, mkdirSync, openSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

if (process.env.AUTONOM_DESKTOP_MANAGED === "1")
{
    delete process.env.AUTONOM_DESKTOP_MANAGED;
    await import("./main.js");
}
else
{
    let log;
    try
    {
        const config = JSON.parse(readFileSync(new URL("./autonom-install.json", import.meta.url), "utf8"));
        const directory = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "autonom");
        mkdirSync(directory, { recursive: true, mode: 0o700 });
        log = openSync(join(directory, "launcher.log"),
            constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
        const args = process.argv.slice(1);
        const debug = args.includes("--debug");
        const child = spawn(config.node, [
            config.launcher,
            "--wait-for-pid",
            String(process.pid),
            "--desktop",
            process.execPath,
            ...(debug ? ["--debug"] : []),
            "--desktop-args",
            ...args.filter((argument) => argument !== "--debug"),
        ], {
            cwd: process.env.VSCODE_CWD || process.cwd(),
            detached: true,
            stdio: ["ignore", log, log],
            env: { ...process.env, AUTONOM_NODE: config.node },
        });
        child.once("spawn", () =>
        {
            child.unref();
            closeSync(log);
            app.exit(0);
        });
        child.once("error", async (error) =>
        {
            closeSync(log);
            console.error("[autonom] Cannot start launcher:", error.message);
            await import("./main.js");
        });
    }
    catch (error)
    {
        if (log !== undefined)
            closeSync(log);

        console.error("[autonom] Cannot start launcher:", error.message);
        await import("./main.js");
    }
}
