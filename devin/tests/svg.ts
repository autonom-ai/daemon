import { after, beforeEach } from "node:test";

/** Minimal SVG element stub: renderer marks only set attributes and append children. */
export class MockSvgElement
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

/** Serve `document.createElementNS` from the stub for every test in this file. */
export function installSvgDocument(): void
{
    const original = (globalThis as any).document;
    beforeEach(() =>
    {
        (globalThis as any).document = {
            createElementNS: (namespaceURI: string, tagName: string) => new MockSvgElement(namespaceURI, tagName),
        };
    });
    after(() =>
    {
        (globalThis as any).document = original;
    });
}
