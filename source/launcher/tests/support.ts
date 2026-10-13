import type { CenterContent } from "../content";

export type Fixture = {
    services: any;
    base: any;
    listeners: Set<() => void>;
    commands: unknown[];
};

export function fixture(): Fixture
{
    const listeners = new Set<() => void>();
    const base = {
        revision: "native",
        schemaVersion: 7,
        items: [{ id: "automations", label: "Automations", icon: "automations", path: "/automations" }],
    };
    const manifest = {
        getManifest(): any
        {
            return base;
        },
        _onDidChangeManifest: {
            fire(): void
            {
                for (const listener of listeners)
                    listener();
            },
        },
        onDidChangeManifest(listener: () => void): { dispose(): void }
        {
            listeners.add(listener);
            return {
                dispose(): void
                {
                    listeners.delete(listener);
                },
            };
        },
    };
    const commands: unknown[] = [];
    let active: { id: string; path: string } | null = null;
    const groups = {
        getActiveNavSurface(): unknown
        {
            return active;
        },
        setActiveNavSurface(_window: number, surface: { id: string; path: string } | null): void
        {
            active = surface;
        },
    };
    const controller = {
        show(): void
        {
            return;
        },
        setVisible(): void
        {
            return;
        },
        resetActiveSurface(): void
        {
            return;
        },
        reloadActiveSurface(): void
        {
            return;
        },
        _load(): void
        {
            return;
        },
    };
    return {
        services: {
            manifest,
            groups,
            controller,
            windowId: 2,
            api: {
                async executeCommand(command: string, surface: { id: string; path: string }): Promise<void>
                {
                    commands.push({ command, surface });
                    active = surface;
                },
            },
        },
        base,
        listeners,
        commands,
    };
}

export const CONTENT: CenterContent = {
    enabled: true,
    revision: "demo",
    items: [{ id: "automations", label: "Jared", tab: "hello" }],
    tabs: { hello: { title: "Hello", html: "<h1>Hello world</h1>" } },
};

export const BRIDGE = { url: "http://127.0.0.1:1", token: "unit-token" };

export function config(content: CenterContent = CONTENT): { content: CenterContent; bridge: typeof BRIDGE }
{
    return { content, bridge: BRIDGE };
}
