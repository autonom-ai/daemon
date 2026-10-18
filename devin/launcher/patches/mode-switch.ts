import uiCss from "../../../assets/ui.css";
import { createAcpIcons } from "./icons/renderer";
import { Patches, restorePatches } from "./lifecycle";
import { shellIcons } from "./mode-icons";
import { createPatch } from "./status";

const leaseTimeout = 30000;
const transitionDelay = 150;
type Mode = "autonom" | "devin-cloud" | "editor";

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

    const owner = createPatch("mode-switch");
    const style = document.createElement("style");
    style.textContent = css;
    owner.cleanup(() => style.remove());
    document.head.appendChild(style);
    const switches = new Map<HTMLElement, {
        host: HTMLElement;
        patches: Patches;
        agent: HTMLButtonElement;
        editor: HTMLButtonElement;
    }>();
    let requested: "autonom" | "devin-cloud" = "autonom";
    let lease: ReturnType<typeof setTimeout> | undefined;
    let frame: ReturnType<typeof setTimeout> | undefined;
    let disposed = false;
    let transition = 0;
    const timers = new Map<ReturnType<typeof setTimeout>, () => void>();
    function delay(callback: () => void, duration: number, cancel = () => {}): void
    {
        const timer = setTimeout(() =>
        {
            timers.delete(timer);
            if (!disposed)
                callback();
            else
                cancel();
        }, duration);
        timers.set(timer, cancel);
    }
    let acp: ReturnType<typeof createAcpIcons>;
    try
    {
        acp = createAcpIcons(icons ?? {}, render);
    }
    catch (error)
    {
        owner.restore();
        throw error;
    }
    owner.cleanup(() => acp.dispose());
    let observer: MutationObserver;
    try
    {
        observer = new MutationObserver((records) =>
        {
            acp.changed(records);
            frame ??= setTimeout(() =>
            {
                frame = undefined;
                render();
            });
        });
    }
    catch (error)
    {
        owner.restore();
        throw error;
    }

    function forward(root: HTMLElement, button: HTMLButtonElement | null): void
    {
        const patch = new Patches("mode-switch.forward");
        patch.style(root, "display", "");
        try
        {
            button?.click();
        }
        finally
        {
            patch.restore();
        }
    }

    function render(): void
    {
        if (disposed)
            return;

        observer.disconnect();
        for (const [root, entry] of switches)
        {
            if (root.isConnected && entry.host.isConnected)
                continue;

            entry.patches.restore();
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
                entry.patches.restore();
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
                        const pending = ++transition;
                        const nativeAgent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
                        const nativeEditor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
                        if (mode === "editor")
                        {
                            forward(root, nativeEditor);
                            delay(() =>
                            {
                                if (pending !== transition)
                                    return;

                                if (!shell.editorActive())
                                    void target.__autonomCenter?.toggleEditor()
                                        .catch((error: Error) => console.error("[autonom]", error));

                                render();
                            }, 150);
                            return;
                        }

                        requested = mode;
                        const switching = nativeEditor?.getAttribute("aria-pressed") === "true";
                        if (switching)
                            forward(root, nativeAgent);

                        const center = target.__autonomCenter;
                        if (center)
                            void center.setMode(mode)
                                .then(async () =>
                                {
                                    if (disposed || pending !== transition || target.__autonomCenter !== center
                                        || mode !== "autonom")
                                        return;

                                    if (switching)
                                        await new Promise<void>((resolve_) => delay(resolve_, transitionDelay, resolve_));

                                    if (!disposed && pending === transition && target.__autonomCenter === center
                                        && !shell.editorActive())
                                        await center.revealAgentSidebar();
                                })
                                .catch((error: Error) => console.error("[autonom]", error));
                        render();
                    });
                    host.appendChild(button);
                }

                const patches = new Patches("mode-switch.element");
                patches.cleanup(() => host.remove());
                patches.style(root, "display", "none");
                entry = { host, agent, editor, patches };
                switches.set(root, entry);
                root.after(host);

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

    owner.cleanup(() =>
    {
        try
        {
            return restorePatches([...switches.values()].map((entry) => entry.patches));
        }
        finally
        {
            switches.clear();
        }
    });
    owner.cleanup(() =>
    {
        clearTimeout(lease);
        clearTimeout(frame);
        observer.disconnect();
        for (const [timer, cancel] of timers)
        {
            clearTimeout(timer);
            cancel();
        }
        timers.clear();
    });
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
            owner.restore();
        },
    };
    try
    {
        owner.set(target, "__autonomShell", shell);
        shell.heartbeat();
        return shell;
    }
    catch (error)
    {
        disposed = true;
        owner.restore();
        throw error;
    }
}
