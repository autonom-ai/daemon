import { entryIcon } from "../../../../launcher/patches/center/entries";
import { installSvgDocument, type MockSvgElement } from "../../../svg";

import assert from "node:assert/strict";
import { test } from "node:test";

installSvgDocument();

test("entry rows prefer a declared mark over the profile identicon", () =>
{
    const hash = entryIcon({ name: "ada", icon: "hash" }) as unknown as MockSvgElement;
    assert.equal(hash.getAttribute("viewBox"), "0 0 24 24");
    assert.equal(hash.getAttribute("stroke"), "currentColor");
    assert.equal(hash.children.length, 4);
    assert.ok(hash.children.every((child) => child.tagName === "line"));
});

test("entry rows without a declared mark render the name's identicon", () =>
{
    const absent = entryIcon({ name: "ada" }) as unknown as MockSvgElement;
    const unknown = entryIcon({ name: "ada", icon: "no-such-mark" }) as unknown as MockSvgElement;
    for (const icon of [absent, unknown])
    {
        assert.equal(icon.getAttribute("viewBox"), "-1.5 -1.5 8 8");
        assert.equal(icon.getAttribute("fill"), "hsl(320 95% 45%)");
        assert.ok(icon.children.every((child) => child.tagName === "rect"));
    }
});
