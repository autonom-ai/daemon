import { modelCatalog, destination } from "../../source/protocol";
import { renderMarkdown } from "../../source/webview/messages";
import { contentText, date, escape } from "../../source/webview/dom";

import assert from "node:assert/strict";
import { test } from "node:test";

test("Markdown escapes raw HTML and rejects active links", () =>
{
    const markup = renderMarkdown('<img src=x onerror="alert(1)"> **strong** [bad](javascript:alert(1))');
    assert.ok(markup.includes("&lt;img"));
    assert.ok(markup.includes("<strong>strong</strong>"));
    assert.ok(!markup.includes("<img"));
    assert.ok(!markup.includes('href="javascript:'));
});

test("Remote markdown images do not trigger network requests", () =>
{
    const markup = renderMarkdown("![Provider image](https://example.com/tracking.png)");
    assert.ok(!markup.includes("<img"));
    assert.ok(markup.includes("Provider image"));
});

test("User text is escaped for both HTML and attributes", () =>
{
    assert.equal(escape('<script>"&\''), "&lt;script&gt;&quot;&amp;&#39;");
});

test("Coordination timestamps are converted from year-one milliseconds", () =>
{
    assert.equal(date(62135596800000 + 1700000000000)?.getTime(), 1700000000000);
    assert.equal(date(1700000000)?.getTime(), 1700000000000);
    assert.equal(date(1700000000000)?.getTime(), 1700000000000);
});

test("Structured text content renders without interpreting embedded objects", () =>
{
    assert.equal(contentText([{ type: "text", text: "hello" }, { type: "image", data: "secret" }]), "hello");
    assert.equal(contentText({ text: "hi" }), "hi");
});

test("Model catalog normalizes only advertised identifiers", () =>
{
    assert.deepEqual(modelCatalog({ families: [{ family_label: "SWE-2", variants: [
        { model_uid: "swe-2-medium", label: "Medium", cost_tier: "Free" }, { label: "Missing id" },
    ] }] }), [{ id: "swe-2-medium", label: "Medium", family: "SWE-2", cost: "Free" }]);
    assert.deepEqual(modelCatalog(null), []);
});

test("Selections reject unknown destinations and oversized identifiers", () =>
{
    assert.equal(destination({ kind: "system", id: "x" }), undefined);
    assert.equal(destination({ kind: "room", id: "x".repeat(129) }), undefined);
    assert.deepEqual(destination({ kind: "room", id: "general" }), { kind: "room", id: "general" });
});
