import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../../assets/icons/autonom.svg";
import uiCss from "../../../assets/ui.css";

import { createAcpIcons } from "../acp/icons";

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

/** The pinned workbench marks its root while the Agent sidebar is hidden. */
export function agentSidebarHidden(): boolean
{
    return Boolean(globalThis.document?.querySelector(".monaco-workbench")?.classList.contains("noauxiliarybar"));
}

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
    const switches = new Map<HTMLElement, {
        host: HTMLElement;
        display: string;
        agent: HTMLButtonElement;
        editor: HTMLButtonElement;
    }>();
    let requested: "autonom" | "devin-cloud" = "autonom";
    let lease: ReturnType<typeof setTimeout> | undefined;
    let frame: ReturnType<typeof setTimeout> | undefined;
    let disposed = false;
    const acp = createAcpIcons(icons ?? {}, render);
    const observer = new MutationObserver((records) =>
    {
        acp.changed(records);
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

                        const center = target.__autonomCenter;
                        if (center)
                            void center.setMode(mode)
                                .then(() => mode === "autonom" ? center.revealAgentSidebar() : undefined)
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
                : target.__autonomCenter?.mode?.() ?? target.__autonomCenter?.status().mode ?? requested;
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

        acp.render();
        observer.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["aria-pressed", "style", "class", "src"] });
    }

    const shell = {
        performance: () => acp.performance(),
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
                acp.update(nextIcons);

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

            acp.dispose();
            style.remove();
            if (target.__autonomShell === shell)
                delete target.__autonomShell;
        },
    };
    target.__autonomShell = shell;
    shell.heartbeat();
    render();
    return shell;
}
