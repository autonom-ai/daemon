type SavedIcon = { properties: [string, string, string][]; attribute: string | null };

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

export function createAcpIcons(initial: Record<string, string>, invalidate: () => void)
{
    const sheet = document.createElement("style");
    sheet.textContent = acpCodiconSheet;
    document.head.appendChild(sheet);
    const patchedIcons = new Map<Element, SavedIcon>();
    const resolvedIcons = new Map<string, string | null>();
    const acpSessionProviders = new Map<string, string | null>();
    const dirty = new Set<Document | Element>([document]);
    let recorded = new WeakSet<object>();
    let acpIcons = initial;
    let scans = 0;
    let candidates = 0;
    let milliseconds = 0;
    let disposed = false;

    function remember(element: Element): void
    {
        if (patchedIcons.has(element))
            return;

        const style = (element as HTMLElement).style;
        patchedIcons.set(element, {
            properties: [...acpIconStyle.map(([name]) => name), "--acp-icon"].map((name) =>
                [name, style.getPropertyValue(name), style.getPropertyPriority(name)]),
            attribute: element.getAttribute("data-acp-icon"),
        });
    }

    function clear(element: Element, original: SavedIcon): void
    {
        const style = (element as HTMLElement).style;
        for (const [name, value, priority] of original.properties)
        {
            if (value)
                style.setProperty(name, value, priority);
            else
                style.removeProperty(name);
        }

        if (original.attribute === null)
            element.removeAttribute("data-acp-icon");
        else
            element.setAttribute("data-acp-icon", original.attribute);
    }

    function acpRegistryIcon(element: Element): string | undefined
    {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        const target = key ? (element as any)[key] : null;
        let fiber = target;
        for (let index = 0; fiber && index < 16; index++, fiber = fiber.return)
        {
            const props = fiber.memoizedProps;
            acpRecordSessions(props);
            const providerId = acpProviderId(props);
            if (providerId === undefined)
                continue;

            return acpIconSlot(element, target, fiber, props) ? acpIcons[providerId] : undefined;
        }
        return acpCodiconIcon(element);
    }

    function acpRecordSessions(props: any): void
    {
        if (!props || recorded.has(props))
            return;

        recorded.add(props);
        for (const value of Object.values(props))
        {
            if (Array.isArray(value))
                value.forEach(acpRecordSession);
            else
                acpRecordSession(value);
        }
    }

    function acpRecordSession(session: unknown): void
    {
        if (!session || typeof session !== "object")
            return;
        const { sessionId, providerId } = session as { sessionId?: unknown; providerId?: unknown };
        if (typeof sessionId !== "string" || typeof providerId !== "string")
            return;
        const slug = sessionId.split("/").pop();
        if (!slug)
            return;
        const known = acpSessionProviders.get(slug);
        if (known === undefined)
            acpSessionProviders.set(slug, providerId);
        else if (known !== providerId)
            acpSessionProviders.set(slug, null);
    }

    function acpCodiconIcon(element: Element): string | undefined
    {
        if (!element.classList?.contains("codicon-devin-logo"))
            return undefined;
        const scope = element.closest(".monaco-icon-label") ?? element.closest(".quick-input-list-row");
        const description = scope?.querySelector(".monaco-icon-description-container")?.textContent?.trim();
        if (description && acpIcons[description])
            return acpIcons[description];
        const slug = element.closest("[data-resource-name]")?.getAttribute("data-resource-name");
        const providerId = slug ? acpSessionProviders.get(slug) : undefined;
        return providerId ? acpIcons[providerId] : undefined;
    }

    function acpProviderId(props: any): string | undefined
    {
        if (typeof props?.providerId === "string")
            return props.providerId;
        if (typeof props?.agent?.id === "string")
            return props.agent.id;
        if (typeof props?.agentId === "string")
            return props.agentId;
        if (typeof props?.session?.providerId === "string")
            return props.session.providerId;
        return undefined;
    }

    function acpIconSlot(element: Element, target: any, fiber: any, props: any): boolean
    {
        if (typeof props?.session?.providerId === "string" && acpProviderId(props) === props.session.providerId)
        {
            const child = fiber.child;
            if (!("isWaiting" in props && "size" in props) || !child || child.tag !== 5)
                return false;
            for (let probe = target; probe && probe !== fiber; probe = probe.return)
            {
                if (probe === child)
                    return true;
            }
            return false;
        }

        const icon = props?.icon;
        if (icon && typeof icon === "object")
        {
            for (let probe = target; probe && probe !== fiber; probe = probe.return)
            {
                if (probe.memoizedProps === icon.props)
                    return true;
            }
            return false;
        }
        return fiber.stateNode === element || acpFirstHost(fiber) === element;
    }

    function acpFirstHost(fiber: any): Element | null
    {
        let node = fiber.child;
        while (node)
        {
            if (node.tag === 5 && node.stateNode)
                return node.stateNode;
            if (node.child)
            {
                node = node.child;
                continue;
            }
            while (node !== fiber && !node.sibling)
                node = node.return;
            node = node === fiber ? null : node.sibling;
        }
        return null;
    }

    function acpIconUrl(icon: string): string | undefined
    {
        if (!/^https?:/i.test(icon))
            return icon;
        const cached = resolvedIcons.get(icon);
        if (cached !== undefined)
            return cached ?? undefined;
        resolvedIcons.set(icon, null);
        void fetch(icon)
            .then(async (response) =>
            {
                if (!response.ok)
                    return;
                const type = response.headers.get("content-type")?.split(";")[0] || "image/svg+xml";
                const bytes = new Uint8Array(await response.arrayBuffer());
                let binary = "";
                for (let index = 0; index < bytes.length; index += 8192)
                    binary += String.fromCharCode(...bytes.subarray(index, index + 8192));
                resolvedIcons.set(icon, `data:${type};base64,${btoa(binary)}`);
                dirty.add(document);
                invalidate();
            })
            .catch(() => {});
        return undefined;
    }

    function applyAcpIcon(element: Element, icon: string): void
    {
        const url = acpIconUrl(icon);
        if (url === undefined)
            return;

        remember(element);
        const style = (element as HTMLElement).style;
        const mask = `url("${url.replace(/["\\]/g, "\\$&")}")`;
        const className = typeof element.className === "string" ? element.className : "";
        if (/\bcodicon-/.test(className))
        {
            element.setAttribute("data-acp-icon", "");
            style.setProperty("--acp-icon", mask);
            return;
        }
        for (const [name, value] of acpIconStyle)
        {
            const next = name.endsWith("mask-image") ? mask : value;
            if (style.getPropertyValue(name) !== next)
                style.setProperty(name, next);
        }
    }

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
                    clear(element, original);
                    patchedIcons.delete(element);
                }
            }

            if (!dirty.size)
                return;

            const started = performance.now();
            recorded = new WeakSet();
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
                const icon = acpRegistryIcon(element);
                if (icon !== undefined)
                    applyAcpIcon(element, icon);
                else if (patchedIcons.has(element))
                {
                    clear(element, patchedIcons.get(element)!);
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
            for (const [element, original] of patchedIcons)
                clear(element, original);

            patchedIcons.clear();
            dirty.clear();
            sheet.remove();
        },
    };
}
