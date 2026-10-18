import type { CenterContent, SidebarItem } from "../../../launcher/center/content";
import { createLayout } from "../../../launcher/center/layout";

import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

class MockElement
{
    readonly tagName: string;
    readonly namespaceURI: string | undefined;
    readonly attributes = new Map<string, string>();
    readonly children: MockElement[] = [];
    readonly dataset: Record<string, string> = {};
    readonly style: any;
    parentElement: MockElement | null = null;
    isConnected = true;
    textContent = "";

    constructor(tagName: string, namespaceURI?: string)
    {
        this.tagName = tagName.toUpperCase();
        this.namespaceURI = namespaceURI;
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

    removeChild<T extends MockElement>(child: T): T
    {
        const index = this.children.indexOf(child);
        if (index !== -1)
        {
            this.children.splice(index, 1);
            child.parentElement = null;
            child.isConnected = false;
        }
        return child;
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

    replaceChildren(...newChildren: MockElement[]): void
    {
        for (const child of this.children)
        {
            child.parentElement = null;
            child.isConnected = false;
        }
        this.children.length = 0;
        for (const child of newChildren)
        {
            child.parentElement = this;
            child.isConnected = this.isConnected;
            this.children.push(child);
        }
    }

    replaceWith(newElement: MockElement): void
    {
        if (!this.parentElement)
            return;

        const index = this.parentElement.children.indexOf(this);
        if (index !== -1)
        {
            newElement.parentElement = this.parentElement;
            newElement.isConnected = this.parentElement.isConnected;
            this.parentElement.children.splice(index, 1, newElement);
        }
        this.parentElement = null;
        this.isConnected = false;
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
    if (selector === 'ul[aria-label="Pages"]')
        return elem.tagName === "UL" && elem.getAttribute("aria-label") === "Pages";
    if (selector === '[data-slot="sidebar-menu-button"] > button[aria-label]')
        return elem.tagName === "BUTTON" && elem.getAttribute("aria-label") !== null
            && elem.parentElement?.getAttribute("data-slot") === "sidebar-menu-button";
    if (selector === '[data-slot="sidebar-menu-button-icon"]')
        return elem.getAttribute("data-slot") === "sidebar-menu-button-icon";
    if (selector === "button[data-autonom-item]")
        return elem.tagName === "BUTTON" && elem.dataset.autonomItem !== undefined;
    if (selector === 'div[data-slot="sidebar-label-row"]')
        return elem.tagName === "DIV" && elem.getAttribute("data-slot") === "sidebar-label-row";
    if (selector === '[data-slot="sidebar-group"]')
        return elem.getAttribute("data-slot") === "sidebar-group";
    if (selector === '[data-slot="sidebar-group-label"]')
        return elem.getAttribute("data-slot") === "sidebar-group-label";
    if (selector === "[data-autonom-section]")
        return elem.dataset.autonomSection !== undefined;
    if (selector === ".agent-editor-switch")
        return (elem.getAttribute("class") ?? "").split(/\s+/).includes("agent-editor-switch");
    if (selector === "svg")
        return elem.tagName === "SVG";
    if (selector === "button")
        return elem.tagName === "BUTTON";
    return false;
}

let mockDocument: any;
const originalDocument = (globalThis as any).document;
const originalMutationObserver = (globalThis as any).MutationObserver;

beforeEach(() =>
{
    const head = new MockElement("head");
    const body = new MockElement("body");
    mockDocument = {
        head,
        body,
        createElement: (tag: string) => new MockElement(tag),
        createElementNS: (ns: string, tag: string) => new MockElement(tag, ns),
        querySelectorAll: (selector: string) => body.querySelectorAll(selector),
        addEventListener: () => { return; },
        removeEventListener: () => { return; },
    };
    (globalThis as any).document = mockDocument;
    (globalThis as any).MutationObserver = class
    {
        observe(): void { return; }
        disconnect(): void { return; }
    };
});

afterEach(() =>
{
    (globalThis as any).document = originalDocument;
    (globalThis as any).MutationObserver = originalMutationObserver;
});

function createSidebarTree(items: Array<{ id: string; label: string; hasSlot?: boolean }>): {
    menu: MockElement;
    buttons: Map<string, { button: MockElement; slot: MockElement | null; initialSvg: MockElement }>;
}
{
    const menu = new MockElement("ul");
    menu.setAttribute("aria-label", "Pages");
    mockDocument.body.appendChild(menu);

    const buttons = new Map<string, { button: MockElement; slot: MockElement | null; initialSvg: MockElement }>();

    for (const item of items)
    {
        const row = new MockElement("li");
        menu.appendChild(row);

        const menuButtonWrapper = new MockElement("div");
        menuButtonWrapper.setAttribute("data-slot", "sidebar-menu-button");
        row.appendChild(menuButtonWrapper);

        const button = new MockElement("button");
        button.setAttribute("aria-label", item.label);
        (button as any).__reactFiber$test = {
            memoizedProps: { tab: item.id },
            return: null,
        };
        menuButtonWrapper.appendChild(button);

        const initialSvg = new MockElement("svg");
        initialSvg.setAttribute("class", "native-devin-icon");

        let slot: MockElement | null = null;
        if (item.hasSlot !== false)
        {
            slot = new MockElement("span");
            slot.setAttribute("data-slot", "sidebar-menu-button-icon");
            slot.appendChild(initialSvg);
            button.appendChild(slot);
        }
        else
            button.appendChild(initialSvg);

        const labelSpan = new MockElement("span");
        labelSpan.textContent = item.label;
        button.appendChild(labelSpan);

        buttons.set(item.id, { button, slot, initialSvg });
    }

    return { menu, buttons };
}

function makeContent(): CenterContent
{
    return {
        enabled: true,
        items: [
            { id: "schedules", label: "Schedules", icon: "timer" },
            { id: "policy", label: "Policy", icon: "shield-lock" },
            { id: "settings", label: "Settings", icon: "cog" },
        ],
        sections: [],
    };
}

function makeItemsMap(content: CenterContent): Map<string, SidebarItem>
{
    const ret = new Map<string, SidebarItem>();
    for (const item of content.items ?? [])
        ret.set(item.id, item);
    return ret;
}

test("renderSections injects bundled Lucide SVGs into [data-slot=sidebar-menu-button-icon]", () =>
{
    const content = makeContent();
    const items = makeItemsMap(content);
    const { buttons } = createSidebarTree([
        { id: "schedules", label: "Schedules" },
        { id: "policy", label: "Policy" },
        { id: "settings", label: "Settings" },
    ]);

    const layout = createLayout({
        content,
        items,
        enabled: true,
        activate: async () => { return; },
    });

    layout.render();

    // Verify Schedules (timer)
    const schedules = buttons.get("schedules")!;
    assert.equal(schedules.button.dataset.autonomItem, "schedules");
    assert.equal(schedules.slot!.dataset.autonomIcon, "timer");
    assert.equal(schedules.slot!.children.length, 1);
    const timerSvg = schedules.slot!.children[0]!;
    assert.equal(timerSvg.tagName, "SVG");
    assert.equal(timerSvg.getAttribute("stroke"), "currentColor");
    assert.equal(timerSvg.getAttribute("viewBox"), "0 0 24 24");
    assert.notEqual(timerSvg, schedules.initialSvg);

    // Verify Policy (shield-lock)
    const policy = buttons.get("policy")!;
    assert.equal(policy.button.dataset.autonomItem, "policy");
    assert.equal(policy.slot!.dataset.autonomIcon, "shield-lock");
    assert.equal(policy.slot!.children.length, 1);
    const shieldSvg = policy.slot!.children[0]!;
    assert.equal(shieldSvg.tagName, "SVG");
    assert.equal(shieldSvg.getAttribute("stroke"), "currentColor");
    assert.notEqual(shieldSvg, policy.initialSvg);

    // Verify Settings (cog)
    const settings = buttons.get("settings")!;
    assert.equal(settings.button.dataset.autonomItem, "settings");
    assert.equal(settings.slot!.dataset.autonomIcon, "cog");
    assert.equal(settings.slot!.children.length, 1);
    const cogSvg = settings.slot!.children[0]!;
    assert.equal(cogSvg.tagName, "SVG");
    assert.equal(cogSvg.getAttribute("stroke"), "currentColor");
    assert.notEqual(cogSvg, settings.initialSvg);

    layout.dispose();
});

test("repeated renderSections calls are idempotent and preserve existing SVG elements", () =>
{
    const content = makeContent();
    const items = makeItemsMap(content);
    const { buttons } = createSidebarTree([
        { id: "schedules", label: "Schedules" },
        { id: "policy", label: "Policy" },
        { id: "settings", label: "Settings" },
    ]);

    const layout = createLayout({
        content,
        items,
        enabled: true,
        activate: async () => { return; },
    });

    // First render
    layout.render();

    const schedulesSlot = buttons.get("schedules")!.slot!;
    const firstTimerSvg = schedulesSlot.children[0]!;
    const policySlot = buttons.get("policy")!.slot!;
    const firstPolicySvg = policySlot.children[0]!;
    const settingsSlot = buttons.get("settings")!.slot!;
    const firstSettingsSvg = settingsSlot.children[0]!;

    // Second render
    layout.render();

    // Elements should be identical references (idempotent, no DOM replacement)
    assert.equal(schedulesSlot.children[0], firstTimerSvg);
    assert.equal(schedulesSlot.dataset.autonomIcon, "timer");

    assert.equal(policySlot.children[0], firstPolicySvg);
    assert.equal(policySlot.dataset.autonomIcon, "shield-lock");

    assert.equal(settingsSlot.children[0], firstSettingsSvg);
    assert.equal(settingsSlot.dataset.autonomIcon, "cog");

    // Third render
    layout.render();
    assert.equal(schedulesSlot.children[0], firstTimerSvg);
    assert.equal(policySlot.children[0], firstPolicySvg);
    assert.equal(settingsSlot.children[0], firstSettingsSvg);

    layout.dispose();
});

test("fallback replaces direct svg when sidebar-menu-button-icon container is absent", () =>
{
    const content = makeContent();
    const items = makeItemsMap(content);
    const { buttons } = createSidebarTree([
        { id: "schedules", label: "Schedules", hasSlot: false },
    ]);

    const layout = createLayout({
        content,
        items,
        enabled: true,
        activate: async () => { return; },
    });

    const schedules = buttons.get("schedules")!;
    assert.equal(schedules.slot, null);
    assert.equal(schedules.button.children[0], schedules.initialSvg);

    layout.render();

    const replacedSvg = schedules.button.querySelector<MockElement>("svg")!;
    assert.ok(replacedSvg);
    assert.notEqual(replacedSvg, schedules.initialSvg);
    assert.equal((replacedSvg as any).dataset?.autonomIcon, "timer");
    assert.equal(replacedSvg.getAttribute("stroke"), "currentColor");

    // Repeated render remains idempotent
    layout.render();
    const secondSvg = schedules.button.querySelector<MockElement>("svg")!;
    assert.equal(secondSvg, replacedSvg);

    layout.dispose();
});

test("unbundled and unknown icons leave original native icons untouched", () =>
{
    const content: CenterContent = {
        enabled: true,
        items: [
            { id: "wiki", label: "Wiki", icon: "wiki" },
            { id: "custom", label: "Custom" },
        ],
        sections: [],
    };
    const items = makeItemsMap(content);
    const { buttons } = createSidebarTree([
        { id: "wiki", label: "Wiki" },
        { id: "custom", label: "Custom" },
    ]);

    const layout = createLayout({
        content,
        items,
        enabled: true,
        activate: async () => { return; },
    });

    layout.render();

    // Wiki has no bundled SVG, initialSvg remains untouched
    const wiki = buttons.get("wiki")!;
    assert.equal(wiki.slot!.children[0], wiki.initialSvg);
    assert.equal(wiki.slot!.dataset.autonomIcon, undefined);

    // Custom has no icon property, initialSvg remains untouched
    const custom = buttons.get("custom")!;
    assert.equal(custom.slot!.children[0], custom.initialSvg);
    assert.equal(custom.slot!.dataset.autonomIcon, undefined);

    layout.dispose();
});
