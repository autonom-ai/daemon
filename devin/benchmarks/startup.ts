import type { CdpSession } from "../launcher/cdp/client";
import { click, connectBrowser } from "../tests/cdp";

import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";

/** Open a separate native window; observe the actual production runtime and DOM. */
async function main(): Promise<void>
{
    const workspace = process.argv[2];
    const output = process.argv[3];
    if (!workspace || !output)
        throw new Error("Usage: node dist/benchmarks/startup.js <workspace> <output.json>");

    const browser = await connectBrowser();
    const previous = new Set((await browser.client.targets()).map((target) => target.id));
    const started = performance.now();
    const observations: Record<string, unknown> = { workspace: resolve(workspace), startedAt: new Date().toISOString() };
    let session: CdpSession | undefined;
    let requested = false;
    let ready = false;
    const child = spawn("devin-desktop", ["--new-window", resolve(workspace)], { stdio: "ignore" });
    let spawnError: Error | undefined;
    child.on("error", (error) => { spawnError = error; });
    const deadline = performance.now() + 60000;
    try
    {
        while (!ready && performance.now() < deadline)
        {
            if (spawnError)
                throw spawnError;

            if (!session)
            {
                const target = (await browser.client.targets()).find((entry) => !previous.has(entry.id)
                    && entry.type === "page" && entry.url.includes("/workbench/workbench.html"));
                if (target)
                {
                    observations.targetId = target.id;
                    observations.targetObservedMs = performance.now() - started;
                    session = await browser.client.attach(target.id);
                }
            }

            if (session)
            {
                const snapshot = await session.evaluate(`(() => {
                    const center = globalThis.__autonomCenter;
                    return {
                        dom: document.readyState !== "loading", shell: Boolean(globalThis.__autonomShell),
                        center: Boolean(center), timeOrigin: performance.timeOrigin,
                        sidebar: Boolean(center && [...document.querySelectorAll("[data-autonom-section]")].some(element => {
                            const rect = element.getBoundingClientRect(); return rect.width > 0 && rect.height > 0;
                        }))
                    };
                })()`).catch(() => undefined) as Record<string, unknown> | undefined;
                if (snapshot)
                {
                    observations.rendererTimeOrigin = snapshot.timeOrigin;
                    for (const phase of ["dom", "shell", "center", "sidebar"])
                        if (snapshot[phase] && observations[`${phase}ObservedMs`] === undefined)
                            observations[`${phase}ObservedMs`] = performance.now() - started;

                    if (snapshot.shell && !requested)
                    {
                        await click(session, '[data-autonom-mode="autonom"]');
                        requested = true;
                        observations.autonomRequestedMs = performance.now() - started;
                    }

                    ready = snapshot.sidebar === true;
                }
            }

            if (!ready)
                await new Promise((resolve) => setTimeout(resolve, 25));
        }

        observations.ready = ready;
        await writeFile(output, JSON.stringify(observations, null, 2) + "\n", { mode: 0o600 });
        if (!ready)
            throw new Error(`The native sidebar did not become ready; partial timings saved to ${output}`);

        console.log(JSON.stringify(observations));
    }
    finally
    {
        await session?.detach();
        browser.close();
    }
}

void main().catch((error: unknown) =>
{
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
});
