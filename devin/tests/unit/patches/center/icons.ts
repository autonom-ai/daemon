import { createIcon, identicon, sectionIcon } from "../../../../launcher/patches/center/icons";
import { installSvgDocument, type MockSvgElement } from "../../../svg";

import assert from "node:assert/strict";
import { test } from "node:test";

installSvgDocument();

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

test("createIcon parses stroke-based Lucide settings mark with its gear circle", () =>
{
    const icon = createIcon("settings") as unknown as MockSvgElement;
    assert.ok(icon);
    assert.equal(icon.tagName, "svg");
    assert.equal(icon.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(icon.getAttribute("fill"), "none");
    assert.equal(icon.getAttribute("stroke"), "currentColor");
    assert.equal(icon.getAttribute("stroke-width"), "2");

    assert.equal(icon.children.length, 2);
    const [gear, circle] = icon.children;
    assert.equal(gear?.tagName, "path");
    assert.ok(gear?.getAttribute("d")?.startsWith("M9.671 4.136a2.34 2.34 0 0 1 4.659 0"));
    assert.equal(circle?.tagName, "circle");
    assert.equal(circle?.getAttribute("cx"), "12");
    assert.equal(circle?.getAttribute("cy"), "12");
    assert.equal(circle?.getAttribute("r"), "3");

    assert.equal(createIcon("cog"), undefined);
});

test("createIcon parses stroke-based Lucide settings-2 mark with two knobs", () =>
{
    const icon = createIcon("settings-2") as unknown as MockSvgElement;
    assert.ok(icon);
    assert.equal(icon.tagName, "svg");
    assert.equal(icon.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(icon.getAttribute("fill"), "none");
    assert.equal(icon.getAttribute("stroke"), "currentColor");
    assert.equal(icon.getAttribute("stroke-width"), "2");

    assert.equal(icon.children.length, 4);
    const [bottomLine, topLine, bottomKnob, topKnob] = icon.children;
    assert.equal(bottomLine?.tagName, "path");
    assert.equal(bottomLine?.getAttribute("d"), "M14 17H5");
    assert.equal(topLine?.tagName, "path");
    assert.equal(topLine?.getAttribute("d"), "M19 7h-9");
    assert.equal(bottomKnob?.tagName, "circle");
    assert.equal(bottomKnob?.getAttribute("cx"), "17");
    assert.equal(bottomKnob?.getAttribute("cy"), "17");
    assert.equal(bottomKnob?.getAttribute("r"), "3");
    assert.equal(topKnob?.tagName, "circle");
    assert.equal(topKnob?.getAttribute("cx"), "7");
    assert.equal(topKnob?.getAttribute("cy"), "7");
    assert.equal(topKnob?.getAttribute("r"), "3");

    assert.equal(createIcon("sliders"), undefined);
});

test("createIcon parses stroke-based Lucide plus and search marks", () =>
{
    const plus = createIcon("plus") as unknown as MockSvgElement;
    assert.ok(plus);
    assert.equal(plus.tagName, "svg");
    assert.equal(plus.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(plus.getAttribute("fill"), "none");
    assert.equal(plus.getAttribute("stroke"), "currentColor");
    assert.equal(plus.getAttribute("stroke-width"), "2");
    assert.equal(plus.children.length, 2);
    assert.equal(plus.children[0]?.tagName, "path");
    assert.equal(plus.children[0]?.getAttribute("d"), "M5 12h14");
    assert.equal(plus.children[1]?.tagName, "path");
    assert.equal(plus.children[1]?.getAttribute("d"), "M12 5v14");

    const search = createIcon("search") as unknown as MockSvgElement;
    assert.ok(search);
    assert.equal(search.tagName, "svg");
    assert.equal(search.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(search.getAttribute("fill"), "none");
    assert.equal(search.getAttribute("stroke"), "currentColor");
    assert.equal(search.getAttribute("stroke-width"), "2");
    assert.equal(search.children.length, 2);
    assert.equal(search.children[0]?.tagName, "path");
    assert.equal(search.children[0]?.getAttribute("d"), "m21 21-4.34-4.34");
    assert.equal(search.children[1]?.tagName, "circle");
    assert.equal(search.children[1]?.getAttribute("cx"), "11");
    assert.equal(search.children[1]?.getAttribute("cy"), "11");
    assert.equal(search.children[1]?.getAttribute("r"), "8");
});

test("createIcon parses stroke-based Lucide x, close, cloud, and pencil marks", () =>
{
    for (const name of ["x", "close"])
    {
        const closeIcon = createIcon(name) as unknown as MockSvgElement;
        assert.ok(closeIcon);
        assert.equal(closeIcon.getAttribute("viewBox"), "0 0 24 24");
        assert.equal(closeIcon.getAttribute("stroke"), "currentColor");
        assert.equal(closeIcon.children.length, 2);
        assert.equal(closeIcon.children[0]?.getAttribute("d"), "M18 6 6 18");
        assert.equal(closeIcon.children[1]?.getAttribute("d"), "m6 6 12 12");
    }

    const cloud = createIcon("cloud") as unknown as MockSvgElement;
    assert.ok(cloud);
    assert.equal(cloud.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(cloud.getAttribute("stroke"), "currentColor");
    assert.equal(cloud.children.length, 1);
    assert.equal(cloud.children[0]?.getAttribute("d"), "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z");

    const pencil = createIcon("pencil") as unknown as MockSvgElement;
    assert.ok(pencil);
    assert.equal(pencil.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(pencil.getAttribute("stroke"), "currentColor");
    assert.equal(pencil.children.length, 2);
});

test("createIcon parses custom marks retaining local definitions", () =>
{
    const autonom = createIcon("autonom") as unknown as MockSvgElement;
    assert.ok(autonom);
    assert.equal(autonom.tagName, "svg");
    assert.equal(autonom.getAttribute("viewBox"), "0 0 48 48");
    assert.equal(autonom.children.length, 1);
    assert.equal(autonom.children[0]?.tagName, "path");
    assert.equal(autonom.children[0]?.getAttribute("fill-rule"), "evenodd");

    const autonomFill = createIcon("autonom-fill") as unknown as MockSvgElement;
    assert.ok(autonomFill);
    assert.equal(autonomFill.tagName, "svg");
    assert.equal(autonomFill.getAttribute("viewBox"), "0 0 48 48");
    assert.equal(autonomFill.children.length, 1);
    assert.equal(autonomFill.children[0]?.tagName, "path");
    assert.equal(autonomFill.children[0]?.getAttribute("fill-rule"), "evenodd");
});

/** Cells the installed minidenticons renders for the left half of the `ada` 5x5 grid. */
const adaCells = [["1", "2"], ["1", "4"], ["2", "0"], ["2", "2"], ["2", "3"], ["2", "4"], ["3", "2"], ["3", "4"]];

function cells(icon: MockSvgElement): string[][]
{
    return icon.children.map((child) => [child.getAttribute("x")!, child.getAttribute("y")!]);
}

test("identicon fills the deterministic minidenticons grid for the profile name", () =>
{
    const icon = identicon("ada") as unknown as MockSvgElement;
    assert.equal(icon.tagName, "svg");
    assert.equal(icon.getAttribute("viewBox"), "-1.5 -1.5 8 8");
    assert.equal(icon.getAttribute("fill"), "hsl(320 95% 45%)");
    assert.equal(icon.getAttribute("stroke"), null);
    assert.equal(icon.getAttribute("aria-hidden"), "true");
    assert.deepEqual(cells(icon), adaCells);
    assert.ok(icon.children.every((child) => child.tagName === "rect"
        && child.getAttribute("width") === "1" && child.getAttribute("height") === "1"));
});

test("identicon seeds from the lowercased name and varies with the profile", () =>
{
    const ada = identicon("ada") as unknown as MockSvgElement;
    const capital = identicon("Ada") as unknown as MockSvgElement;
    assert.deepEqual(cells(capital), adaCells);
    assert.equal(capital.getAttribute("fill"), ada.getAttribute("fill"));

    const other = identicon("bob") as unknown as MockSvgElement;
    assert.notDeepEqual(cells(other), cells(ada));
    assert.notEqual(other.getAttribute("fill"), ada.getAttribute("fill"));
});

test("createIcon returns undefined for unknown icon without fallback", () =>
{
    assert.equal(createIcon(undefined), undefined);
    assert.equal(createIcon("nonexistent-mark"), undefined);
    assert.equal(createIcon("user"), undefined);
});

test("createIcon and sectionIcon resolve fallback when primary icon is unknown", () =>
{
    const fallbackTimer = createIcon("nonexistent", "timer") as unknown as MockSvgElement;
    assert.ok(fallbackTimer);
    assert.equal(fallbackTimer.children.length, 3);
    assert.equal(fallbackTimer.children[0]?.tagName, "line");

    const defaultSection = sectionIcon(undefined) as unknown as MockSvgElement;
    assert.ok(defaultSection);
    assert.equal(defaultSection.children.length, 2);
    assert.equal(defaultSection.children[0]?.tagName, "path");

    const customSection = sectionIcon("settings-2") as unknown as MockSvgElement;
    assert.ok(customSection);
    assert.equal(customSection.children.length, 4);
});
