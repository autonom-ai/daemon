import { prepareShell } from "../../../launcher/center/shell";

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

const acpIconSelector = "svg, img, span[style*='mask-image']";

class StubStyle
{
    private readonly values = new Map<string, string>();

    getPropertyValue(name: string): string
    {
        return this.values.get(name) ?? "";
    }

    setProperty(name: string, value: string): void
    {
        this.values.set(name, value);
    }

    removeProperty(name: string): void
    {
        this.values.delete(name);
    }
}

function providerElement(providerId: string): any
{
    const provider = { memoizedProps: { providerId, icon: "native" }, return: null };
    return {
        isConnected: true,
        style: new StubStyle(),
        __reactFiber$probe: { memoizedProps: {}, return: { memoizedProps: {}, return: provider } },
    };
}

function mountDom(elements: any[]): void
{
    const styleElement = { textContent: "", remove: () => undefined };
    (globalThis as any).document = {
        head: { appendChild: () => undefined },
        body: {},
        createElement: () => styleElement,
        createElementNS: () => ({}),
        querySelectorAll: (selector: string) =>
            selector === acpIconSelector ? elements.filter((element) => element.isConnected) : [],
    };
    (globalThis as any).MutationObserver = class
    {
        observe(): void
        {
        }

        disconnect(): void
        {
        }
    };
}

afterEach(() =>
{
    const target = globalThis as any;
    target.__autonomShell?.dispose();
    delete target.__autonomShell;
    delete target.document;
    delete target.MutationObserver;
});

test("registry icons survive shell re-entry and are removed on dispose", () =>
{
    const element = providerElement("devin-autonom");
    mountDom([element]);
    const icons = { "devin-autonom": "data:image/svg+xml;base64,QUJD" };
    const mask = `url("${icons["devin-autonom"]}")`;
    const shell = prepareShell("", icons);
    try
    {
        assert.equal(element.style.getPropertyValue("mask-image"), mask);
        assert.equal(element.style.getPropertyValue("background-color"), "currentColor");
        assert.equal(prepareShell(""), shell);
        assert.equal(element.style.getPropertyValue("mask-image"), mask);
    }
    finally
    {
        shell.dispose();
    }

    assert.equal(element.style.getPropertyValue("mask-image"), "");
    assert.equal(element.style.getPropertyValue("background-color"), "");
});

test("registry icons update, clear, and follow element connectivity", () =>
{
    const element = providerElement("devin-autonom");
    mountDom([element]);
    const first = `url("data:image/svg+xml;base64,QUJD")`;
    const second = `url("data:image/svg+xml;base64,REVG")`;
    const shell = prepareShell("", { "devin-autonom": "data:image/svg+xml;base64,QUJD" });
    try
    {
        shell.update("", { "devin-autonom": "data:image/svg+xml;base64,REVG" });
        assert.equal(element.style.getPropertyValue("mask-image"), second);
        element.style.removeProperty("mask-image");
        shell.update("");
        assert.equal(element.style.getPropertyValue("mask-image"), second);
        element.isConnected = false;
        shell.update("");
        assert.equal(element.style.getPropertyValue("mask-image"), "");
        element.isConnected = true;
        shell.update("");
        assert.equal(element.style.getPropertyValue("mask-image"), second);
        shell.update("", {});
        assert.equal(element.style.getPropertyValue("mask-image"), "");
        shell.update("", { "devin-autonom": "data:image/svg+xml;base64,QUJD" });
        assert.equal(element.style.getPropertyValue("mask-image"), first);
    }
    finally
    {
        shell.dispose();
    }
});
