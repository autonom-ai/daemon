import { prepareShell } from "../../../launcher/center/shell";

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

const acpIconSelector = "svg, img, [style*='mask-image'], [role='img'], div:not(:has(*)), span:not(:has(*))";

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

class MockElement
{
    readonly tagName: string;
    readonly attributes = new Map<string, string>();
    readonly children: MockElement[] = [];
    readonly dataset: Record<string, string> = {};
    readonly style: any;
    parentElement: MockElement | null = null;
    isConnected = true;
    textContent = "";
    title = "";
    type = "";
    private readonly listeners = new Map<string, Array<() => void>>();

    constructor(tagName: string)
    {
        this.tagName = tagName.toUpperCase();
        this.style = {
            display: "",
            getPropertyValue: (name: string) => this.style[name] ?? "",
            setProperty: (name: string, value: string) => { this.style[name] = value; },
            removeProperty: (name: string) => { delete this.style[name]; },
        };
    }

    setAttribute(name: string, value: string): void
    {
        this.attributes.set(name, value);
    }

    getAttribute(name: string): string | null
    {
        return this.attributes.get(name) ?? null;
    }

    removeAttribute(name: string): void
    {
        this.attributes.delete(name);
    }

    appendChild<T extends MockElement>(child: T): T
    {
        child.parentElement = this;
        child.isConnected = this.isConnected;
        this.children.push(child);
        return child;
    }

    after(newElement: MockElement): void
    {
        if (!this.parentElement)
            return;

        const index = this.parentElement.children.indexOf(this);
        if (index !== -1)
        {
            newElement.parentElement = this.parentElement;
            newElement.isConnected = this.parentElement.isConnected;
            this.parentElement.children.splice(index + 1, 0, newElement);
        }
    }

    remove(): void
    {
        this.isConnected = false;
        if (this.parentElement)
        {
            const index = this.parentElement.children.indexOf(this);
            if (index !== -1)
                this.parentElement.children.splice(index, 1);
            this.parentElement = null;
        }
    }

    addEventListener(event: string, listener: () => void): void
    {
        const list = this.listeners.get(event) ?? [];
        list.push(listener);
        this.listeners.set(event, list);
    }

    click(): void
    {
        for (const listener of this.listeners.get("click") ?? [])
            listener();
    }

    getBoundingClientRect(): { width: number; height: number }
    {
        return { width: 100, height: 24 };
    }

    querySelector<T = MockElement>(selector: string): T | null
    {
        return (this.querySelectorAll<T>(selector)[0] ?? null) as T | null;
    }

    querySelectorAll<T = MockElement>(selector: string): T[]
    {
        const matches: MockElement[] = [];
        const match = (elem: MockElement) =>
        {
            if (matchesSelector(elem, selector))
                matches.push(elem);
            for (const child of elem.children)
                match(child);
        };

        for (const child of this.children)
            match(child);

        return matches as T[];
    }
}

function matchesSelector(elem: MockElement, selector: string): boolean
{
    if (selector === ".agent-editor-switch")
        return (elem.getAttribute("class") ?? "").split(/\s+/).includes("agent-editor-switch");
    if (selector === 'button[aria-label="Agent"]')
        return elem.tagName === "BUTTON" && elem.getAttribute("aria-label") === "Agent";
    if (selector === 'button[aria-label="Editor"]')
        return elem.tagName === "BUTTON" && elem.getAttribute("aria-label") === "Editor";
    if (selector === "button")
        return elem.tagName === "BUTTON";
    if (selector === "svg")
        return elem.tagName === "SVG";
    if (selector === "path")
        return elem.tagName === "PATH";
    if (selector === "[data-autonom-mode-switch]")
        return elem.dataset.autonomModeSwitch !== undefined;
    if (selector.startsWith('button[data-autonom-mode="'))
    {
        const mode = selector.slice('button[data-autonom-mode="'.length, -2);
        return elem.tagName === "BUTTON" && elem.dataset.autonomMode === mode;
    }
    return false;
}

function fiberNode(tag: number, memoizedProps: any): any
{
    return { tag, memoizedProps, stateNode: null, child: null, sibling: null, return: null };
}

function hostElement(): any
{
    return { isConnected: true, style: new StubStyle() };
}

function hostFiber(element: any, memoizedProps: any = {}): any
{
    const fiber = fiberNode(5, memoizedProps);
    fiber.stateNode = element;
    element.__reactFiber$probe = fiber;
    return fiber;
}

function fiberChild(parent: any, ...children: any[]): void
{
    parent.child = children[0] ?? null;
    for (let index = 0; index < children.length; index += 1)
    {
        children[index].return = parent;
        children[index].sibling = children[index + 1] ?? null;
    }
}

function providerElement(providerId: string): any
{
    const element = hostElement();
    const provider = fiberNode(0, { providerId, icon: "native" });
    fiberChild(provider, hostFiber(element));
    return element;
}

let mockDocument: any;

function mountDom(elements: any[] = []): { body: MockElement; head: MockElement }
{
    const head = new MockElement("head");
    const body = new MockElement("body");
    mockDocument = {
        head,
        body,
        createElement: (tag: string) => new MockElement(tag),
        createElementNS: (_ns: string, tag: string) => new MockElement(tag),
        querySelectorAll: (selector: string) =>
        {
            if (selector === acpIconSelector)
                return elements.filter((element) => element.isConnected);
            return body.querySelectorAll(selector);
        },
    };
    (globalThis as any).document = mockDocument;
    (globalThis as any).MutationObserver = class
    {
        observe(): void
        {
        }

        disconnect(): void
        {
        }
    };
    return { body, head };
}

afterEach(() =>
{
    const target = globalThis as any;
    target.__autonomShell?.dispose();
    delete target.__autonomShell;
    delete target.__autonomCenter;
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

test("registry icons apply to agent letter-avatar elements", () =>
{
    const element = hostElement();
    element.textContent = "AN";
    const avatar = fiberNode(0, { agent: { id: "devin-better-antigravity", name: "Antigravity" } });
    fiberChild(avatar, hostFiber(element));
    mountDom([element]);

    const mask = `url("data:image/svg+xml;base64,QUJD")`;
    const shell = prepareShell("", { "devin-better-antigravity": "data:image/svg+xml;base64,QUJD" });
    try
    {
        assert.equal(element.style.getPropertyValue("mask-image"), mask);
        assert.equal(element.style.getPropertyValue("font-size"), "0");
    }
    finally
    {
        shell.dispose();
    }

    assert.equal(element.style.getPropertyValue("mask-image"), "");
    assert.equal(element.style.getPropertyValue("font-size"), "");
});

test("registry icons do not apply to provider elements outside the icon slot", () =>
{
    const avatar = hostElement();
    const label = hostElement();
    const row = fiberNode(0, { agent: { id: "devin-autonom", name: "Autonom" } });
    fiberChild(row, hostFiber(avatar), hostFiber(label));
    mountDom([avatar, label]);

    const mask = `url("data:image/svg+xml;base64,QUJD")`;
    const shell = prepareShell("", { "devin-autonom": "data:image/svg+xml;base64,QUJD" });
    try
    {
        assert.equal(avatar.style.getPropertyValue("mask-image"), mask);
        assert.equal(label.style.getPropertyValue("mask-image"), "");
    }
    finally
    {
        shell.dispose();
    }
});

test("registry icons leave providers without registry icons untouched", () =>
{
    const element = providerElement("devin-cli");
    mountDom([element]);
    const shell = prepareShell("", { "devin-autonom": "data:image/svg+xml;base64,QUJD" });
    try
    {
        assert.equal(element.style.getPropertyValue("mask-image"), "");
        assert.equal(element.style.getPropertyValue("background-color"), "");
    }
    finally
    {
        shell.dispose();
    }
});

test("registry icons apply inside provider icon element props", () =>
{
    const element = hostElement();
    const other = hostElement();
    const slot = fiberNode(0, { labelledBy: "agent" });
    fiberChild(slot, hostFiber(element));
    const provider = fiberNode(0, { providerId: "devin-autonom", icon: { props: slot.memoizedProps } });
    fiberChild(provider, slot, hostFiber(other));
    mountDom([element, other]);

    const mask = `url("data:image/svg+xml;base64,QUJD")`;
    const shell = prepareShell("", { "devin-autonom": "data:image/svg+xml;base64,QUJD" });
    try
    {
        assert.equal(element.style.getPropertyValue("mask-image"), mask);
        assert.equal(other.style.getPropertyValue("mask-image"), "");
    }
    finally
    {
        shell.dispose();
    }
});

test("registry icons fetch remote URLs and apply the resolved data", async () =>
{
    const element = providerElement("devin-better-antigravity");
    mountDom([element]);
    const bytes = new TextEncoder().encode("<svg/>");
    const requests: string[] = [];
    const originalFetch = (globalThis as any).fetch;
    (globalThis as any).fetch = async (url: string) =>
    {
        requests.push(url);
        return {
            ok: true,
            headers: { get: () => "image/svg+xml" },
            arrayBuffer: async () => bytes.buffer,
        };
    };

    const shell = prepareShell("", { "devin-better-antigravity": "https://cdn.example/icon.svg" });
    try
    {
        assert.equal(element.style.getPropertyValue("mask-image"), "");
        await new Promise((resolve) => setTimeout(resolve, 10));
        assert.equal(requests.length, 1);
        const mask = element.style.getPropertyValue("mask-image");
        assert.ok(mask.startsWith('url("data:image/svg+xml;base64,'));
    }
    finally
    {
        (globalThis as any).fetch = originalFetch;
        shell.dispose();
    }
});

test("mode switch toolbar replaces .agent-editor-switch with Autonom, Devin Cloud, and Editor buttons", () =>
{
    const { body } = mountDom();
    const container = new MockElement("div");
    body.appendChild(container);

    const switchRoot = new MockElement("div");
    switchRoot.setAttribute("class", "agent-editor-switch");
    container.appendChild(switchRoot);

    const nativeAgent = new MockElement("button");
    nativeAgent.setAttribute("aria-label", "Agent");
    nativeAgent.setAttribute("aria-pressed", "true");
    switchRoot.appendChild(nativeAgent);

    const nativeEditor = new MockElement("button");
    nativeEditor.setAttribute("aria-label", "Editor");
    nativeEditor.setAttribute("aria-pressed", "false");
    switchRoot.appendChild(nativeEditor);

    const shell = prepareShell();
    try
    {
        assert.equal(switchRoot.style.display, "none");
        const toolbar = container.querySelector<MockElement>("[data-autonom-mode-switch]");
        assert.ok(toolbar);
        assert.equal(toolbar.getAttribute("role"), "group");
        assert.equal(toolbar.getAttribute("aria-label"), "Workspace mode");

        const buttons = toolbar.querySelectorAll<MockElement>("button");
        assert.equal(buttons.length, 3);

        const autonomBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="autonom"]');
        assert.ok(autonomBtn);
        assert.equal(autonomBtn.getAttribute("aria-label"), "Autonom");
        const autonomSvg = autonomBtn.querySelector<MockElement>("svg");
        assert.ok(autonomSvg);
        assert.equal(autonomSvg.getAttribute("viewBox"), "0 0 48 48");
        assert.equal(autonomSvg.getAttribute("stroke"), null);
        const autonomPath = autonomSvg.querySelector<MockElement>("path");
        assert.ok(autonomPath);
        assert.equal(autonomPath.getAttribute("fill-rule"), "evenodd");

        const cloudBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="devin-cloud"]');
        assert.ok(cloudBtn);
        assert.equal(cloudBtn.getAttribute("aria-label"), "Devin Cloud");
        const cloudSvg = cloudBtn.querySelector<MockElement>("svg");
        assert.ok(cloudSvg);
        assert.equal(cloudSvg.getAttribute("viewBox"), "0 0 24 24");
        assert.equal(cloudSvg.getAttribute("stroke"), "currentColor");
        assert.equal(cloudSvg.getAttribute("stroke-width"), "2");
        assert.equal(cloudSvg.getAttribute("stroke-linecap"), "round");
        assert.equal(cloudSvg.getAttribute("stroke-linejoin"), "round");
        const cloudPath = cloudSvg.querySelector<MockElement>("path");
        assert.ok(cloudPath);
        assert.equal(cloudPath.getAttribute("fill-rule"), null);
        assert.equal(cloudPath.getAttribute("d"), "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z");

        const editorBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="editor"]');
        assert.ok(editorBtn);
        assert.equal(editorBtn.getAttribute("aria-label"), "Editor");
        const editorSvg = editorBtn.querySelector<MockElement>("svg");
        assert.ok(editorSvg);
        assert.equal(editorSvg.getAttribute("viewBox"), "0 0 24 24");
        assert.equal(editorSvg.getAttribute("stroke"), "currentColor");
        assert.equal(editorSvg.getAttribute("stroke-width"), "2");
        assert.equal(editorSvg.getAttribute("stroke-linecap"), "round");
        assert.equal(editorSvg.getAttribute("stroke-linejoin"), "round");
        const editorPath = editorSvg.querySelector<MockElement>("path");
        assert.ok(editorPath);
        assert.equal(editorPath.getAttribute("fill-rule"), null);
        assert.ok(editorPath.getAttribute("d")?.includes("m15 5 4 4"));
    }
    finally
    {
        shell.dispose();
    }

    assert.equal(switchRoot.style.display, "");
    assert.equal(container.querySelector("[data-autonom-mode-switch]"), null);
});

test("mode switch toolbar swaps active and inactive state attributes (aria-pressed, fill, d)", () =>
{
    const { body } = mountDom();
    const container = new MockElement("div");
    body.appendChild(container);

    const switchRoot = new MockElement("div");
    switchRoot.setAttribute("class", "agent-editor-switch");
    container.appendChild(switchRoot);

    const nativeAgent = new MockElement("button");
    nativeAgent.setAttribute("aria-label", "Agent");
    nativeAgent.setAttribute("aria-pressed", "true");
    switchRoot.appendChild(nativeAgent);

    const nativeEditor = new MockElement("button");
    nativeEditor.setAttribute("aria-label", "Editor");
    nativeEditor.setAttribute("aria-pressed", "false");
    switchRoot.appendChild(nativeEditor);

    const shell = prepareShell();
    try
    {
        const toolbar = container.querySelector<MockElement>("[data-autonom-mode-switch]")!;
        const autonomBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="autonom"]')!;
        const cloudBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="devin-cloud"]')!;
        const editorBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="editor"]')!;

        // Initial state: autonom active
        assert.equal(autonomBtn.getAttribute("aria-pressed"), "true");
        assert.equal(cloudBtn.getAttribute("aria-pressed"), "false");
        assert.equal(editorBtn.getAttribute("aria-pressed"), "false");

        assert.equal(cloudBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        assert.equal(editorBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        const editorLineD = editorBtn.querySelector<MockElement>("path")?.getAttribute("d")!;
        assert.ok(editorLineD.includes("m15 5 4 4"));

        // Switch to devin-cloud
        cloudBtn.click();
        assert.equal(autonomBtn.getAttribute("aria-pressed"), "false");
        assert.equal(cloudBtn.getAttribute("aria-pressed"), "true");
        assert.equal(editorBtn.getAttribute("aria-pressed"), "false");

        assert.equal(cloudBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "currentColor");
        assert.equal(editorBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        assert.equal(editorBtn.querySelector<MockElement>("path")?.getAttribute("d"), editorLineD);

        // Switch to editor via native editor toggle
        nativeEditor.setAttribute("aria-pressed", "true");
        nativeAgent.setAttribute("aria-pressed", "false");
        shell.heartbeat();

        assert.equal(autonomBtn.getAttribute("aria-pressed"), "false");
        assert.equal(cloudBtn.getAttribute("aria-pressed"), "false");
        assert.equal(editorBtn.getAttribute("aria-pressed"), "true");

        assert.equal(editorBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "currentColor");
        assert.equal(cloudBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        const editorFillD = editorBtn.querySelector<MockElement>("path")?.getAttribute("d")!;
        assert.ok(!editorFillD.includes("m15 5 4 4"));
        assert.notEqual(editorFillD, editorLineD);

        // Switch back to autonom
        nativeEditor.setAttribute("aria-pressed", "false");
        nativeAgent.setAttribute("aria-pressed", "true");
        autonomBtn.click();

        assert.equal(autonomBtn.getAttribute("aria-pressed"), "true");
        assert.equal(cloudBtn.getAttribute("aria-pressed"), "false");
        assert.equal(editorBtn.getAttribute("aria-pressed"), "false");
        assert.equal(editorBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        assert.equal(cloudBtn.querySelector<MockElement>("svg")?.getAttribute("fill"), "none");
        assert.equal(editorBtn.querySelector<MockElement>("path")?.getAttribute("d"), editorLineD);
    }
    finally
    {
        shell.dispose();
    }
});

test("editor mode switch keeps the native switch hidden and falls back to toggleEditor", async () =>
{
    const { body } = mountDom();
    const container = new MockElement("div");
    body.appendChild(container);

    const switchRoot = new MockElement("div");
    switchRoot.setAttribute("class", "agent-editor-switch");
    container.appendChild(switchRoot);

    const nativeAgent = new MockElement("button");
    nativeAgent.setAttribute("aria-label", "Agent");
    nativeAgent.setAttribute("aria-pressed", "true");
    switchRoot.appendChild(nativeAgent);

    const nativeEditor = new MockElement("button");
    nativeEditor.setAttribute("aria-label", "Editor");
    nativeEditor.setAttribute("aria-pressed", "false");
    switchRoot.appendChild(nativeEditor);

    let clicked = 0;
    let toggled = 0;
    nativeEditor.addEventListener("click", () => clicked += 1);
    (globalThis as any).__autonomCenter = {
        status: () => ({ mode: "autonom" }),
        toggleEditor: async () => toggled += 1,
    };

    const shell = prepareShell();
    try
    {
        const toolbar = container.querySelector<MockElement>("[data-autonom-mode-switch]")!;
        const editorBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="editor"]')!;

        editorBtn.click();
        assert.equal(clicked, 1);
        assert.equal(switchRoot.style.display, "none");

        await new Promise((resolve) => setTimeout(resolve, 200));
        assert.equal(switchRoot.style.display, "none");
        assert.equal(toggled, 1);
    }
    finally
    {
        shell.dispose();
    }
});

test("editor mode switch does not call toggleEditor when the native click activates the editor", async () =>
{
    const { body } = mountDom();
    const container = new MockElement("div");
    body.appendChild(container);

    const switchRoot = new MockElement("div");
    switchRoot.setAttribute("class", "agent-editor-switch");
    container.appendChild(switchRoot);

    const nativeAgent = new MockElement("button");
    nativeAgent.setAttribute("aria-label", "Agent");
    nativeAgent.setAttribute("aria-pressed", "true");
    switchRoot.appendChild(nativeAgent);

    const nativeEditor = new MockElement("button");
    nativeEditor.setAttribute("aria-label", "Editor");
    nativeEditor.setAttribute("aria-pressed", "false");
    switchRoot.appendChild(nativeEditor);

    nativeEditor.addEventListener("click", () =>
    {
        nativeEditor.setAttribute("aria-pressed", "true");
        nativeAgent.setAttribute("aria-pressed", "false");
    });
    let toggled = 0;
    (globalThis as any).__autonomCenter = {
        status: () => ({ mode: "autonom" }),
        toggleEditor: async () => toggled += 1,
    };

    const shell = prepareShell();
    try
    {
        const toolbar = container.querySelector<MockElement>("[data-autonom-mode-switch]")!;
        const editorBtn = toolbar.querySelector<MockElement>('button[data-autonom-mode="editor"]')!;

        editorBtn.click();
        assert.equal(switchRoot.style.display, "none");

        await new Promise((resolve) => setTimeout(resolve, 200));
        assert.equal(switchRoot.style.display, "none");
        assert.equal(toggled, 0);
        assert.equal(editorBtn.getAttribute("aria-pressed"), "true");
    }
    finally
    {
        shell.dispose();
    }
});
