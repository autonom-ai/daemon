import { connectWindow } from "../../cdp";

import assert from "node:assert/strict";
import { test } from "node:test";

const target = process.env.AUTONOM_TEST_TARGET;
const provider = process.env.AUTONOM_TEST_ICON_PROVIDER;

/** Requires an actual visible native Agents or session icon for the specified provider. */
test("the selected provider uses its Base64 icon while native labels stay unmasked", {
    skip: !target || !provider,
}, async () =>
{
    const window = await connectWindow(target!);
    try
    {
        const result = await window.session.evaluate(`(() => {
            const provider = ${JSON.stringify(provider)};
            const icon = globalThis.__autonomBundle?.icons?.[provider];
            let canonical = typeof icon === "string"
                && new RegExp("^data:image/[a-z0-9.+-]+;base64,[a-z0-9+/]+={0,2}$", "i").test(icon);
            if (canonical)
            {
                try
                {
                    const payload = icon.slice(icon.indexOf(",") + 1);
                    canonical = btoa(atob(payload)) === payload;
                }
                catch
                {
                    canonical = false;
                }
            }
            const visible = element =>
            {
                const rect = element.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
            };
            const masks = element => [getComputedStyle(element), getComputedStyle(element, "::before")]
                .flatMap(style => [style.maskImage, style.webkitMaskImage])
                .filter(value => value && value !== "none");
            const belongs = element =>
            {
                const key = Object.keys(element).find(name => name.startsWith("__reactFiber$"));
                let fiber = key ? element[key] : null;
                for (let index = 0; fiber && index < 16; index++, fiber = fiber.return)
                {
                    const props = fiber.memoizedProps;
                    const id = props?.providerId ?? props?.agent?.id ?? props?.agentId ?? props?.session?.providerId;
                    if (typeof id === "string")
                        return id === provider;
                }
                return false;
            };
            const hosts = [...document.querySelectorAll(
                "svg, img, [role='img'], .codicon-devin-logo, [style*='mask-image'], div:not(:has(*)), span:not(:has(*))"
            )].filter(visible).filter(belongs);
            const controls = [...document.querySelectorAll(
                'input, textarea, select, label, span.truncate, [data-slot="sidebar-group-label"], '
                + '.monaco-icon-description-container, .monaco-icon-name-container, button[aria-label="New session"]'
            )].filter(visible);
            return {
                canonical,
                providerHosts: hosts.length,
                matchingMasks: canonical ? hosts.filter(element => masks(element).some(mask => mask.includes(icon))).length : 0,
                controls: controls.length,
                maskedControls: controls.filter(element => masks(element).length > 0).length,
            };
        })()`) as {
            canonical: boolean;
            providerHosts: number;
            matchingMasks: number;
            controls: number;
            maskedControls: number;
        };
        assert.equal(result.canonical, true, "The renderer dictionary must contain a canonical Base64 image for this provider.");
        assert.ok(result.providerHosts > 0, "Open the real native Agents settings or a session row for this provider first.");
        assert.ok(result.matchingMasks > 0, "A visible native provider icon must use its dictionary image as a mask.");
        assert.ok(result.controls > 0, "Native labels or inputs must be visible for the preservation assertion.");
        assert.equal(result.maskedControls, 0, "Native labels and inputs must remain unmasked.");
    }
    finally
    {
        await window.close();
    }
});
