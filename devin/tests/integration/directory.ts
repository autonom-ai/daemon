import { click, connectWindow } from "../cdp";
import { DaemonClient } from "../../launcher/daemon/client";
import { defaultDaemonConfigPath } from "../../launcher/config";

import { Hash, User } from "lucide";

import assert from "node:assert/strict";
import { resolve } from "node:path";
import { test } from "node:test";

const target = process.env.AUTONOM_TEST_TARGET;

/** Read the native visible section without counting its retained hidden counterpart. */
function sectionRoot(section: string): HTMLElement
{
    const roots = [...document.querySelectorAll<HTMLElement>(`[data-autonom-section="${section}"]`)]
        .filter((element) => element.getBoundingClientRect().height > 0);
    if (roots.length !== 1)
        throw new Error(`Expected one visible ${section} section, observed ${roots.length}.`);

    return roots[0]!;
}

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
            const header = `(${sectionRoot.toString()})(${JSON.stringify(section)})`;
            const rows = `[...(${header}).querySelectorAll('[data-autonom-directory] > li')]`;
            const observed = await window.session.evaluate(`(() => {
                return ${rows}.map(row => ({
                    name: row.dataset.autonomEntry,
                    icons: row.querySelectorAll('svg').length,
                    actions: row.querySelectorAll('button, a, [role="button"]').length,
                    visible: row.getBoundingClientRect().height > 0,
                    paths: [...row.querySelectorAll('svg > *')].map(element => ({
                        tag: element.tagName,
                        attributes: Object.fromEntries([...element.attributes].map(attribute => [attribute.name, attribute.value]))
                    }))
                }));
            })()`) as { name: string; icons: number; actions: number; visible: boolean; paths: unknown }[];
            assert.deepEqual(observed.map((entry) => entry.name).sort(), expected.map((entry) => entry.name).sort());
            assert.ok(observed.every((entry) => entry.visible && entry.icons === 1 && entry.actions === 0));

            const paths = (icon === "hash" ? Hash : User).map(([tag, attributes]) => ({
                tag,
                attributes: Object.fromEntries(Object.entries(attributes).map(([key, value]) => [key, String(value)])),
            }));
            for (const entry of observed)
                assert.deepEqual(entry.paths, paths);

            await click(window.session, `[data-autonom-section="${section}"] button[aria-label="Search"]`);
            const input = `[data-autonom-section="${section}"] input`;
            await click(window.session, input);
            await window.session.request("Input.insertText", { text: "__autonom_no_matching_entry__" });
            assert.equal(await window.session.evaluate(`${rows}.length`), expected.length);
            assert.equal(await window.session.evaluate(`(() => ${rows}
                .filter(row => row.getBoundingClientRect().height > 0).length)()`), 0);
            assert.equal(await window.session.evaluate(`(${header}).querySelector('[data-autonom-section-empty]')?.textContent`),
                `No ${section} found`);
            await window.session.request("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape" });
            await window.session.request("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape" });
            assert.equal(await window.session.evaluate(`(() => ${rows}
                .filter(row => row.getBoundingClientRect().height > 0).length)()`), expected.length);
            console.log(JSON.stringify({ section, rows: observed.length, icon, search: "passed" }));
        }
    }
    finally
    {
        await window.close();
    }
});
