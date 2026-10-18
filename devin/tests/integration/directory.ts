import { click, connectWindow } from "../cdp";
import { DaemonClient } from "../../launcher/daemon/client";
import { defaultDaemonConfigPath } from "../../launcher/config";

import assert from "node:assert/strict";
import { resolve } from "node:path";
import { test } from "node:test";

const target = process.env.AUTONOM_TEST_TARGET;

test("the live room and profile rows match daemon listings and filter through native section search",
    { skip: !target }, async () =>
{
    const daemon = new DaemonClient({
        port: Number(process.env.AUTONOM_TEST_DAEMON_PORT ?? 8080),
        configFile: process.env.AUTONOM_CONFIG ?? defaultDaemonConfigPath(),
        rootDirectory: resolve(__dirname, "../../.."),
    });
    const window = await connectWindow(target!);
    try
    {
        for (const [section, icon] of [["rooms", "hash"], ["profiles", "user"]])
        {
            const expected = await daemon.request<{ name: string }[]>(`/api/${section}`);
            assert.ok(expected.length > 0, `The actual daemon needs at least one ${section} entry for this live check.`);
            const selector = `[data-autonom-directory="${section}"] > li`;
            const observed = await window.session.evaluate(`(() => {
                return [...document.querySelectorAll(${JSON.stringify(selector)})].map(row => ({
                    name: row.dataset.autonomEntry,
                    icons: row.querySelectorAll('svg').length,
                    actions: row.querySelectorAll('button, a, [role="button"]').length,
                    visible: row.getBoundingClientRect().height > 0,
                    icon: row.querySelector('svg')?.classList.contains(${JSON.stringify(`lucide-${icon}`)})
                }));
            })()`) as { name: string; icons: number; actions: number; visible: boolean; icon: boolean }[];
            assert.deepEqual(observed.map((entry) => entry.name).sort(), expected.map((entry) => entry.name).sort());
            assert.ok(observed.every((entry) => entry.visible && entry.icons === 1 && entry.icon && entry.actions === 0));

            await click(window.session, `[data-autonom-section="${section}"] button[aria-label="Search"]`);
            const input = `[data-autonom-section="${section}"] input`;
            await click(window.session, input);
            await window.session.request("Input.insertText", { text: "__autonom_no_matching_entry__" });
            assert.equal(await window.session.evaluate(`document.querySelectorAll(${JSON.stringify(selector)}).length`), expected.length);
            assert.equal(await window.session.evaluate(`(() => [...document.querySelectorAll(${JSON.stringify(selector)})]
                .filter(row => row.getBoundingClientRect().height > 0).length)()`), 0);
            assert.equal(await window.session.evaluate(`document.querySelector('[data-autonom-section-empty="${section}"]')?.textContent`),
                `No ${section} found`);
            await window.session.request("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape" });
            await window.session.request("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape" });
            assert.equal(await window.session.evaluate(`(() => [...document.querySelectorAll(${JSON.stringify(selector)})]
                .filter(row => row.getBoundingClientRect().height > 0).length)()`), expected.length);
            console.log(JSON.stringify({ section, rows: observed.length, icon, search: "passed" }));
        }
    }
    finally
    {
        await window.close();
    }
});
