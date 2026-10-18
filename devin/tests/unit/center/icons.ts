import { createIcon, sectionIcon } from "../../../launcher/center/icons";

import assert from "node:assert/strict";
import { after, beforeEach, test } from "node:test";

class MockSvgElement
{
    readonly tagName: string;
    readonly namespaceURI: string;
    readonly attributes = new Map<string, string>();
    readonly children: MockSvgElement[] = [];
    parentElement: MockSvgElement | null = null;

    constructor(namespaceURI: string, tagName: string)
    {
        this.namespaceURI = namespaceURI;
        this.tagName = tagName.toLowerCase();
    }

    setAttribute(name: string, value: string): void
    {
        this.attributes.set(name, value);
    }

    getAttribute(name: string): string | null
    {
        return this.attributes.get(name) ?? null;
    }

    appendChild<T extends MockSvgElement>(child: T): T
    {
        child.parentElement = this;
        this.children.push(child);
        return child;
    }
}

const originalDocument = (globalThis as any).document;

beforeEach(() =>
{
    (globalThis as any).document = {
        createElementNS: (ns: string, tag: string) => new MockSvgElement(ns, tag),
    };
});

after(() =>
{
    (globalThis as any).document = originalDocument;
});

test("createIcon parses stroke-based Lucide timer mark with lines and circle", () =>
{
    const icon = createIcon("timer") as unknown as MockSvgElement;
    assert.ok(icon);
    assert.equal(icon.tagName, "svg");
    assert.equal(icon.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(icon.getAttribute("fill"), "none");
    assert.equal(icon.getAttribute("stroke"), "currentColor");
    assert.equal(icon.getAttribute("stroke-width"), "2");
    assert.equal(icon.getAttribute("stroke-linecap"), "round");
    assert.equal(icon.getAttribute("stroke-linejoin"), "round");
    assert.equal(icon.getAttribute("aria-hidden"), "true");

    assert.equal(icon.children.length, 3);
    const [line1, line2, circle] = icon.children;

    assert.equal(line1?.tagName, "line");
    assert.equal(line1?.getAttribute("x1"), "10");
    assert.equal(line1?.getAttribute("x2"), "14");
    assert.equal(line1?.getAttribute("y1"), "2");
    assert.equal(line1?.getAttribute("y2"), "2");

    assert.equal(line2?.tagName, "line");
    assert.equal(line2?.getAttribute("x1"), "12");
    assert.equal(line2?.getAttribute("x2"), "15");
    assert.equal(line2?.getAttribute("y1"), "14");
    assert.equal(line2?.getAttribute("y2"), "11");

    assert.equal(circle?.tagName, "circle");
    assert.equal(circle?.getAttribute("cx"), "12");
    assert.equal(circle?.getAttribute("cy"), "14");
    assert.equal(circle?.getAttribute("r"), "8");
});

test("createIcon parses stroke-based Lucide shield-lock mark and shield-check alias", () =>
{
    for (const name of ["shield-lock", "shield-check"])
    {
        const icon = createIcon(name) as unknown as MockSvgElement;
        assert.ok(icon);
        assert.equal(icon.tagName, "svg");
        assert.equal(icon.getAttribute("viewBox"), "0 0 24 24");
        assert.equal(icon.getAttribute("fill"), "none");
        assert.equal(icon.getAttribute("stroke"), "currentColor");
        assert.equal(icon.getAttribute("stroke-width"), "2");

        assert.equal(icon.children.length, 3);
        const [path1, path2, rect] = icon.children;

        assert.equal(path1?.tagName, "path");
        assert.ok(path1?.getAttribute("d")?.startsWith("M20 9.807V6"));

        assert.equal(path2?.tagName, "path");
        assert.equal(path2?.getAttribute("d"), "M19 17v-2a2 2 0 00-4 0v2");

        assert.equal(rect?.tagName, "rect");
        assert.equal(rect?.getAttribute("x"), "13");
        assert.equal(rect?.getAttribute("y"), "17");
        assert.equal(rect?.getAttribute("width"), "8");
        assert.equal(rect?.getAttribute("height"), "5");
        assert.equal(rect?.getAttribute("rx"), "1");
    }
});

test("createIcon parses stroke-based Lucide cog mark and settings alias", () =>
{
    for (const name of ["cog", "settings"])
    {
        const icon = createIcon(name) as unknown as MockSvgElement;
        assert.ok(icon);
        assert.equal(icon.tagName, "svg");
        assert.equal(icon.getAttribute("viewBox"), "0 0 24 24");
        assert.equal(icon.getAttribute("fill"), "none");
        assert.equal(icon.getAttribute("stroke"), "currentColor");
        assert.equal(icon.getAttribute("stroke-width"), "2");

        const paths = icon.children.filter((c) => c.tagName === "path");
        const circles = icon.children.filter((c) => c.tagName === "circle");

        assert.equal(paths.length, 12);
        assert.equal(circles.length, 2);
        assert.equal(circles[0]?.getAttribute("cx"), "12");
        assert.equal(circles[0]?.getAttribute("cy"), "12");
        assert.equal(circles[0]?.getAttribute("r"), "2");
        assert.equal(circles[1]?.getAttribute("r"), "8");
    }
});

test("createIcon parses filled icons (plus and search) with fill attributes", () =>
{
    const plus = createIcon("plus") as unknown as MockSvgElement;
    assert.ok(plus);
    assert.equal(plus.tagName, "svg");
    assert.equal(plus.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(plus.getAttribute("fill"), "none");
    assert.equal(plus.children.length, 1);
    assert.equal(plus.children[0]?.tagName, "path");
    assert.equal(plus.children[0]?.getAttribute("fill"), "currentColor");
    assert.equal(plus.children[0]?.getAttribute("fill-rule"), "evenodd");
    assert.ok(plus.children[0]?.getAttribute("d")?.length! > 0);

    const search = createIcon("search") as unknown as MockSvgElement;
    assert.ok(search);
    assert.equal(search.tagName, "svg");
    assert.equal(search.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(search.children.length, 1);
    assert.equal(search.children[0]?.tagName, "path");
    assert.equal(search.children[0]?.getAttribute("fill"), "currentColor");
    assert.equal(search.children[0]?.getAttribute("fill-rule"), "evenodd");
});

test("createIcon returns undefined for unknown icon without fallback", () =>
{
    assert.equal(createIcon(undefined), undefined);
    assert.equal(createIcon("nonexistent-mark"), undefined);
});

test("createIcon and sectionIcon resolve fallback when primary icon is unknown", () =>
{
    const fallbackTimer = createIcon("nonexistent", "timer") as unknown as MockSvgElement;
    assert.ok(fallbackTimer);
    assert.equal(fallbackTimer.children.length, 3);
    assert.equal(fallbackTimer.children[0]?.tagName, "line");

    const defaultSection = sectionIcon(undefined) as unknown as MockSvgElement;
    assert.ok(defaultSection);
    assert.equal(defaultSection.children.length, 1);
    assert.equal(defaultSection.children[0]?.tagName, "path");

    const customSection = sectionIcon("cog") as unknown as MockSvgElement;
    assert.ok(customSection);
    assert.equal(customSection.children.length, 14);
});
