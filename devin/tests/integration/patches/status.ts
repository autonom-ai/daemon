import { connectWindow } from "../../cdp";

import assert from "node:assert/strict";
import { test } from "node:test";

const target = process.env.AUTONOM_TEST_TARGET;
const expected = [
    "acp-icons", "mode-switch", "command-center.manifest", "command-center.navigation",
    "command-center.pages", "command-center.sidebar", "command-center.runtime",
];

test("the selected native window reports installed patches and one mode switch", { skip: !target }, async () =>
{
    const window = await connectWindow(target!);
    try
    {
        const result = await window.session.evaluate(`(() => {
            const visible = element =>
            {
                const rect = element.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
            };
            const roots = [...document.querySelectorAll("[data-autonom-mode-switch]")].filter(visible);
            return {
                patches: globalThis.__autonomBundle?.runtime.patchStatus() ?? [],
                switches: roots.length,
                controls: roots.flatMap(root => [...root.querySelectorAll("button")]).filter(visible).length,
                nativePeers: roots.filter(root =>
                {
                    const native = root.previousElementSibling;
                    return native?.matches(".agent-editor-switch")
                        && native.querySelector('button[aria-label="Agent"]')
                        && native.querySelector('button[aria-label="Editor"]');
                }).length,
            };
        })()`) as {
            patches: { name: string; state: string; hooks: unknown[] }[];
            switches: number;
            controls: number;
            nativePeers: number;
        };
        assert.deepEqual(result.patches.map((patch) => patch.name).sort(), [...expected].sort());
        for (const patch of result.patches)
        {
            assert.equal(patch.state, "installed", `${patch.name} must be installed in the selected window.`);
            assert.ok(Array.isArray(patch.hooks) && patch.hooks.length > 0
                && patch.hooks.every((hook) => typeof hook === "string" && hook.length > 0),
                `${patch.name} must identify its native hooks.`);
        }
        assert.equal(result.switches, 1);
        assert.equal(result.controls, 3);
        assert.equal(result.nativePeers, 1, "The visible switch must accompany the real native Agent/Editor root.");
    }
    finally
    {
        await window.close();
    }
});
