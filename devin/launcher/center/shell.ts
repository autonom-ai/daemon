import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../../assets/icons/autonom.svg";
import uiCss from "../../../assets/ui.css";

import { Cloud, Pencil, type IconNode } from "lucide";

const leaseTimeout = 30000;

type Mode = "autonom" | "devin-cloud" | "editor";

interface ShellIcon
{
    viewBox: string;
    line: string;
    fill: string;
    stroked: boolean;
}

function iconSet(lineMarkup: string, fillMarkup: string): ShellIcon
{
    const extractPaths = (markup: string) =>
        [...markup.matchAll(/[\s]d="([^"]+)"/g)].map((match) => match[1]).join(" ");

    return {
        viewBox: /viewBox="([^"]+)"/.exec(lineMarkup)?.[1] ?? "0 0 24 24",
        line: extractPaths(lineMarkup),
        fill: extractPaths(fillMarkup),
        stroked: lineMarkup.includes('stroke="currentColor"'),
    };
}

function iconSetFromNode(lineNode: IconNode, fillNode?: IconNode): ShellIcon
{
    const extract = (node: IconNode) =>
        node.map(([, attrs]) => attrs.d).filter(Boolean).join(" ");

    return {
        viewBox: "0 0 24 24",
        line: extract(lineNode),
        fill: fillNode ? extract(fillNode) : extract(lineNode),
        stroked: true,
    };
}

const shellIcons: Record<Mode, ShellIcon> = {
    autonom: iconSet(autonomLineMarkup, autonomFillMarkup),
    "devin-cloud": iconSetFromNode(Cloud),
    editor: iconSetFromNode(Pencil, Pencil.slice(0, 1)),
};

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

export function prepareShell(css = uiCss, icons?: Record<string, string>): any
{
    const target = globalThis as any;
    if (target.__autonomShell)
    {
        target.__autonomShell.update(css, icons);
        target.__autonomShell.heartbeat();
        return target.__autonomShell;
    }

    const style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);
    const acpStyle = document.createElement("style");
    acpStyle.textContent = acpCodiconSheet;
    document.head.appendChild(acpStyle);
    const switches = new Map<HTMLElement, {
        host: HTMLElement;
        display: string;
        agent: HTMLButtonElement;
        editor: HTMLButtonElement;
    }>();
    const patchedIcons = new Set<Element>();
    const resolvedIcons = new Map<string, string | null>();
    const acpSessionProviders = new Map<string, string | null>();
    let acpIcons = icons ?? {};
    let requested: "autonom" | "devin-cloud" = "autonom";
    let lease: ReturnType<typeof setTimeout> | undefined;
    let frame: ReturnType<typeof setTimeout> | undefined;
    let disposed = false;
    const observer = new MutationObserver(() =>
    {
        frame ??= setTimeout(() =>
        {
            frame = undefined;
            render();
        });
    });

    function render(): void
    {
        if (disposed)
            return;

        observer.disconnect();
        for (const [root, entry] of switches)
        {
            if (root.isConnected && entry.host.isConnected)
                continue;

            root.style.display = entry.display;
            entry.host.remove();
            switches.delete(root);
        }

        for (const root of document.querySelectorAll<HTMLElement>(".agent-editor-switch"))
        {
            const agent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
            const editor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
            if (!agent || !editor || !root.parentElement)
                continue;

            let entry = switches.get(root);
            if (entry && (entry.agent !== agent || entry.editor !== editor))
            {
                root.style.display = entry.display;
                entry.host.remove();
                switches.delete(root);
                entry = undefined;
            }

            if (!entry)
            {
                const host = document.createElement("div");
                host.dataset.autonomModeSwitch = "true";
                host.setAttribute("role", "group");
                host.setAttribute("aria-label", "Workspace mode");
                for (const [mode, label] of [
                    ["autonom", "Autonom"],
                    ["devin-cloud", "Devin Cloud"],
                    ["editor", "Editor"],
                ] as const)
                {
                    const button = document.createElement("button");
                    button.type = "button";
                    button.dataset.autonomMode = mode;
                    button.setAttribute("aria-label", label);
                    button.title = label;
                    const icon = shellIcons[mode];
                    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
                    svg.setAttribute("viewBox", icon.viewBox);
                    svg.setAttribute("aria-hidden", "true");
                    if (icon.stroked)
                    {
                        svg.setAttribute("fill", "none");
                        svg.setAttribute("stroke", "currentColor");
                        svg.setAttribute("stroke-width", "2");
                        svg.setAttribute("stroke-linecap", "round");
                        svg.setAttribute("stroke-linejoin", "round");
                    }
                    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
                    if (!icon.stroked)
                        path.setAttribute("fill-rule", "evenodd");
                    path.setAttribute("d", icon.line);
                    svg.appendChild(path);
                    button.appendChild(svg);
                    button.addEventListener("click", () =>
                    {
                        const nativeAgent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
                        const nativeEditor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
                        if (mode === "editor")
                        {
                            nativeEditor?.click();
                            setTimeout(() =>
                            {
                                if (!shell.editorActive())
                                    void target.__autonomCenter?.toggleEditor()
                                        .catch((error: Error) => console.error("[autonom]", error));

                                render();
                            }, 150);
                            return;
                        }

                        requested = mode;
                        if (nativeEditor?.getAttribute("aria-pressed") === "true")
                            nativeAgent?.click();

                        void target.__autonomCenter?.setMode(mode)
                            .catch((error: Error) => console.error("[autonom]", error));
                        render();
                    });
                    host.appendChild(button);
                }

                entry = { host, agent, editor, display: root.style.display };
                switches.set(root, entry);
                root.after(host);
                root.style.display = "none";
            }

            const mode = editor.getAttribute("aria-pressed") === "true" ? "editor"
                : target.__autonomCenter?.status().mode ?? requested;
            for (const button of entry.host.querySelectorAll<HTMLButtonElement>("button"))
            {
                const active = button.dataset.autonomMode === mode;
                button.setAttribute("aria-pressed", String(active));
                const icon = shellIcons[button.dataset.autonomMode as Mode];
                const svg = button.querySelector("svg");
                const path = button.querySelector("path");
                if (!icon || !path || !svg)
                    continue;

                const d = active ? icon.fill : icon.line;
                if (path.getAttribute("d") !== d)
                    path.setAttribute("d", d);

                if (icon.stroked)
                {
                    const fill = active ? "currentColor" : "none";
                    if (svg.getAttribute("fill") !== fill)
                        svg.setAttribute("fill", fill);
                }
            }
        }

        renderAcpIcons();
        observer.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["aria-pressed"] });
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
        for (const value of Object.values(props ?? {}))
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
                render();
            })
            .catch(() => {});
        return undefined;
    }

    function applyAcpIcon(element: Element, icon: string): void
    {
        const url = acpIconUrl(icon);
        if (url === undefined)
            return;

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

    function clearAcpIcon(element: Element): void
    {
        const style = (element as HTMLElement).style;
        for (const [name] of acpIconStyle)
            style.removeProperty(name);
        style.removeProperty("--acp-icon");
        element.removeAttribute?.("data-acp-icon");
    }

    function renderAcpIcons(): void
    {
        for (const element of patchedIcons)
        {
            const icon = element.isConnected ? acpRegistryIcon(element) : undefined;
            if (icon === undefined)
            {
                clearAcpIcon(element);
                patchedIcons.delete(element);
                continue;
            }

            applyAcpIcon(element, icon);
        }

        if (!Object.keys(acpIcons).length)
            return;

        for (const element of document.querySelectorAll(acpIconSelector))
        {
            const icon = acpRegistryIcon(element);
            if (icon === undefined)
                continue;

            applyAcpIcon(element, icon);
            patchedIcons.add(element);
        }
    }

    const shell = {
        requestedMode(): "autonom" | "devin-cloud"
        {
            return requested;
        },
        editorActive(): boolean
        {
            return [...switches].filter(([, entry]) => entry.host.getBoundingClientRect().width > 0)
                .some(([root]) => root.querySelector('button[aria-label="Editor"]')?.getAttribute("aria-pressed") === "true");
        },
        update(nextCss: string, nextIcons?: Record<string, string>): void
        {
            if (style.textContent !== nextCss)
                style.textContent = nextCss;
            if (nextIcons)
                acpIcons = nextIcons;

            render();
        },
        heartbeat(): void
        {
            clearTimeout(lease);
            lease = setTimeout(() => shell.dispose(), leaseTimeout);
            render();
        },
        dispose(): void
        {
            if (disposed)
                return;

            disposed = true;
            clearTimeout(lease);
            if (frame !== undefined)
                clearTimeout(frame);

            observer.disconnect();
            for (const [root, entry] of switches)
            {
                root.style.display = entry.display;
                entry.host.remove();
            }

            for (const element of patchedIcons)
                clearAcpIcon(element);

            patchedIcons.clear();
            style.remove();
            acpStyle.remove();
            if (target.__autonomShell === shell)
                delete target.__autonomShell;
        },
    };
    target.__autonomShell = shell;
    shell.heartbeat();
    render();
    return shell;
}
