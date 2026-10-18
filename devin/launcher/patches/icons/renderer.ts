import { Patches, restorePatches } from "../lifecycle";
import { createPatch } from "../status";
import { createIconProviders } from "./providers";

const acpIconSelector = "svg, img, [style*='mask-image'], [role='img'], .codicon-devin-logo, div:not(:has(*)), span:not(:has(*))";
const acpCodiconSheet = `[data-acp-icon]:before {
    content: "" !important;
    display: inline-block;
    width: 1em;
    height: 1em;
    background-color: currentColor;
    mask-image: var(--acp-icon);
    -webkit-mask-image: var(--acp-icon);
    mask-size: contain;
    -webkit-mask-size: contain;
    mask-repeat: no-repeat;
    -webkit-mask-repeat: no-repeat;
    mask-position: left center;
    -webkit-mask-position: left center;
}`;
const acpIconStyle: [string, string][] = [
    ["background-color", "currentColor"],
    ["font-size", "0"],
    ["mask-repeat", "no-repeat"],
    ["-webkit-mask-repeat", "no-repeat"],
    ["mask-position", "center"],
    ["-webkit-mask-position", "center"],
    ["mask-size", "contain"],
    ["-webkit-mask-size", "contain"],
    ["mask-image", ""],
    ["-webkit-mask-image", ""],
];

export function createAcpIcons(initial: Record<string, string>, _invalidate: () => void)
{
    const sheet = document.createElement("style");
    sheet.textContent = acpCodiconSheet;
    document.head.appendChild(sheet);
    const patchedIcons = new Map<Element, Patches>();
    const dirty = new Set<Document | Element>([document]);
    let acpIcons = initial;
    const providers = createIconProviders(() => acpIcons);
    const owner = createPatch("acp-icons");
    let scans = 0;
    let candidates = 0;
    let milliseconds = 0;
    let disposed = false;

    function applyAcpIcon(element: Element, icon: string): void
    {
        if (!/^data:image\/[a-z0-9.+-]+;base64,[a-z0-9+/=]+$/i.test(icon))
            return;

        let patch = patchedIcons.get(element);
        if (!patch)
        {
            patch = new Patches("acp-icon");
            patchedIcons.set(element, patch);
        }

        const mask = `url("${icon.replace(/["\\]/g, "\\$&")}")`;
        const className = typeof element.className === "string" ? element.className : "";
        if (/\bcodicon-/.test(className))
        {
            patch.attribute(element, "data-acp-icon", "");
            patch.style(element as HTMLElement, "--acp-icon", mask);
            return;
        }
        for (const [name, value] of acpIconStyle)
        {
            const next = name.endsWith("mask-image") ? mask : value;
            patch.style(element as HTMLElement, name, next);
        }
    }

    owner.cleanup(() =>
    {
        try
        {
            return restorePatches(patchedIcons.values());
        }
        finally
        {
            patchedIcons.clear();
            dirty.clear();
            sheet.remove();
        }
    });
    return {
        changed(records: MutationRecord[]): void
        {
            for (const record of records)
            {
                const element = record.target instanceof Element ? record.target : record.target.parentElement;
                if (!element)
                    continue;

                if (record.type === "attributes" && (record.attributeName === "aria-pressed"
                    || !element.matches(acpIconSelector)))
                    continue;

                dirty.add(element.closest("button, .monaco-list-row, .quick-input-list-row") ?? element);
                if (dirty.size > 128)
                {
                    dirty.clear();
                    dirty.add(document);
                    break;
                }
            }
        },
        render(): void
        {
            if (disposed)
                return;

            for (const [element, original] of patchedIcons)
            {
                if (!element.isConnected)
                {
                    original.restore();
                    patchedIcons.delete(element);
                }
            }

            if (!dirty.size)
                return;

            const started = performance.now();
            providers.begin();
            const roots = dirty.has(document) ? [document] : [...dirty];
            dirty.clear();
            const selected = new Set<Element>();
            for (const root of roots)
            {
                if (root !== document && (root as Element).matches(acpIconSelector))
                    selected.add(root as Element);
                for (const element of root.querySelectorAll(acpIconSelector))
                    selected.add(element);
            }

            for (const element of selected)
            {
                const icon = providers.icon(element);
                if (icon !== undefined)
                    applyAcpIcon(element, icon);
                else if (patchedIcons.has(element))
                {
                    patchedIcons.get(element)!.restore();
                    patchedIcons.delete(element);
                }
            }

            scans++;
            candidates += selected.size;
            milliseconds += performance.now() - started;
        },
        update(next: Record<string, string>): void
        {
            if (JSON.stringify(next) === JSON.stringify(acpIcons))
                return;

            acpIcons = next;
            dirty.add(document);
        },
        performance(): { scans: number; candidates: number; milliseconds: number; patched: number }
        {
            return { scans, candidates, milliseconds, patched: patchedIcons.size };
        },
        dispose(): void
        {
            disposed = true;
            owner.restore();
        },
    };
}
