import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../../assets/icons/autonom.svg";
import cloudFillMarkup from "../../../assets/icons/cloud-fill.svg";
import cloudLineMarkup from "../../../assets/icons/cloud.svg";
import pencilFillMarkup from "../../../assets/icons/pencil-fill.svg";
import pencilLineMarkup from "../../../assets/icons/pencil.svg";
import uiCss from "../../../assets/ui.css";

const leaseTimeout = 30000;

type Mode = "autonom" | "devin-cloud" | "editor";

function iconSet(lineMarkup: string, fillMarkup: string): { viewBox: string; line: string; fill: string }
{
    return {
        viewBox: /viewBox="([^"]+)"/.exec(lineMarkup)?.[1] ?? "0 0 16 16",
        line: /[\s]d="([^"]+)"/.exec(lineMarkup)?.[1] ?? "",
        fill: /[\s]d="([^"]+)"/.exec(fillMarkup)?.[1] ?? "",
    };
}

const shellIcons: Record<Mode, { viewBox: string; line: string; fill: string }> = {
    autonom: iconSet(autonomLineMarkup, autonomFillMarkup),
    "devin-cloud": iconSet(cloudLineMarkup, cloudFillMarkup),
    editor: iconSet(pencilLineMarkup, pencilFillMarkup),
};

const acpIconSelector = "svg, img, span[style*='mask-image']";
const acpIconStyle: [string, string][] = [
    ["background-color", "currentColor"],
    ["mask-repeat", "no-repeat"],
    ["-webkit-mask-repeat", "no-repeat"],
    ["mask-position", "center"],
    ["-webkit-mask-position", "center"],
    ["mask-size", "contain"],
    ["-webkit-mask-size", "contain"],
    ["mask-image", ""],
    ["-webkit-mask-image", ""],
];

export function prepareShell(css = uiCss, icons: Record<string, string> = {}): any
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
    const patchedIcons = new Set<Element>();
    let acpIcons = icons;
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
                    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
                    path.setAttribute("fill-rule", "evenodd");
                    path.setAttribute("d", icon.line);
                    svg.appendChild(path);
                    button.appendChild(svg);
                    button.addEventListener("click", () =>
                    {
                        const restore = switches.get(root)?.display ?? "";
                        root.style.display = restore;
                        const nativeAgent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
                        const nativeEditor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
                        if (mode === "editor")
                        {
                            nativeEditor?.click();
                            setTimeout(() =>
                            {
                                root.style.display = "none";
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
                        root.style.display = "none";
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
                const path = button.querySelector("path");
                if (!icon || !path)
                    continue;

                const d = active ? icon.fill : icon.line;
                if (path.getAttribute("d") !== d)
                    path.setAttribute("d", d);
            }
        }

        renderAcpIcons();
        observer.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["aria-pressed"] });
    }

    function acpRegistryIcon(element: Element): string | undefined
    {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (element as any)[key] : null;
        for (let index = 0; fiber && index < 16; index++, fiber = fiber.return)
        {
            const props = fiber.memoizedProps;
            if (typeof props?.providerId === "string" && "icon" in props)
                return acpIcons[props.providerId];
        }
        return undefined;
    }

    function renderAcpIcons(): void
    {
        for (const element of patchedIcons)
        {
            if (element.isConnected && acpRegistryIcon(element) !== undefined)
                continue;

            const style = (element as HTMLElement).style;
            for (const [name] of acpIconStyle)
                style.removeProperty(name);
            patchedIcons.delete(element);
        }

        if (!Object.keys(acpIcons).length)
            return;

        for (const element of document.querySelectorAll(acpIconSelector))
        {
            const icon = acpRegistryIcon(element);
            if (icon === undefined)
                continue;

            const style = (element as HTMLElement).style;
            const mask = `url("${icon.replace(/["\\]/g, "\\$&")}")`;
            if (style.getPropertyValue("mask-image") !== mask)
            {
                for (const [name, value] of acpIconStyle)
                    style.setProperty(name, name.endsWith("mask-image") ? mask : value);
            }

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
            {
                const style = (element as HTMLElement).style;
                for (const [name] of acpIconStyle)
                    style.removeProperty(name);
            }

            patchedIcons.clear();
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
