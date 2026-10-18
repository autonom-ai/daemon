import { click, connectWindow } from "../cdp";
import { benchmark } from "../../benchmarks/sidebar";

import assert from "node:assert/strict";
import { test } from "node:test";

const target = process.env.AUTONOM_TEST_TARGET;

/** Observe and operate only the explicitly selected, separately opened test window. */
test("the live sidebar retains provider icons across idle shell updates without rescanning", { skip: !target }, async () =>
{
    const sample = await benchmark(target!);
    assert.ok(sample.visibleMasks > 0, "Open the real repository Sessions view with visible provider icons first.");
    assert.ok(sample.metricsBefore && sample.metricsAfter, "The optimized production runtime must be attached.");
    assert.equal((sample.metricsAfter as { scans: number }).scans, (sample.metricsBefore as { scans: number }).scans);
    console.log(JSON.stringify(sample));
});

test("the live mode controls restore Cloud navigation and return to Autonom repeatedly", { skip: !target }, async () =>
{
    const window = await connectWindow(target!);
    try
    {
        for (let i = 0; i < 3; i++)
        {
            await click(window.session, '[data-autonom-mode="devin-cloud"]');
            await new Promise((resolve) => setTimeout(resolve, 100));
            assert.equal(await window.session.evaluate("globalThis.__autonomCenter.status().mode"), "devin-cloud");
            assert.equal(await window.session.evaluate('document.querySelectorAll("[data-autonom-section]").length'), 0);
            await click(window.session, '[data-autonom-mode="autonom"]');
            await new Promise((resolve) => setTimeout(resolve, 100));
            assert.equal(await window.session.evaluate("globalThis.__autonomCenter.status().mode"), "autonom");
            assert.ok(await window.session.evaluate('document.querySelectorAll("[data-autonom-section]").length > 0'));
        }
    }
    finally
    {
        await window.close();
    }
});

test("the live icon patch leaves native labels, inputs, and non-icon controls intact", { skip: !target }, async () =>
{
    const window = await connectWindow(target!);
    try
    {
        const result = await window.session.evaluate(`(() => {
            const labels = [...document.querySelectorAll('input, [data-slot="sidebar-group-label"], .monaco-icon-description-container, .monaco-icon-name-container, button[aria-label="New session"]')];
            return {
                checked: labels.length,
                masked: labels.filter(element => element.style.getPropertyValue("mask-image") || element.style.getPropertyValue("--acp-icon")).length,
                switches: [...document.querySelectorAll('[data-autonom-mode-switch]')]
                    .filter(element => element.getBoundingClientRect().height > 0).length,
                switchCount: [...document.querySelectorAll('[data-autonom-mode-switch] button')]
                    .filter(element => element.getBoundingClientRect().height > 0).length
            };
        })()`) as { checked: number; masked: number; switches: number; switchCount: number };
        assert.ok(result.checked > 3);
        assert.equal(result.masked, 0);
        assert.equal(result.switches, 1);
        assert.equal(result.switchCount, 3);
    }
    finally
    {
        await window.close();
    }
});
