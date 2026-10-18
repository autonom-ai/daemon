import { acpRegistryIcons } from "../acp/registry";
import type { CdpClient, CdpSession } from "../cdp/client";
import { object } from "../parse";
import type { RuntimeConfig } from "./types";
import { installRuntime, prepareWindow, runtimeStatus } from "./window";

export class Windows
{
    readonly sessions = new Map<string, CdpSession>();
    readonly byId = new Map<number, CdpSession>();
    disabled = false;
    found = false;
    private readonly warnings = new Map<string, string>();
    private readonly watches = new Map<string, () => Promise<void>>();
    private readonly firstSeen = new Map<string, number>();
    private refreshing: Promise<void> | undefined;
    private queued = false;
    private icons: Record<string, string> = {};
    private iconsAt = 0;
    private readonly started = performance.now();

    constructor(
        private readonly cdp: CdpClient,
        private readonly urls: string[],
        private readonly payload: () => { source: string; config: RuntimeConfig },
        private readonly log: (message: string) => void,
    )
    { }

    async start(): Promise<void>
    {
        this.disabled = false;
        for (const event of ["Target.targetCreated", "Target.targetInfoChanged", "Target.targetDestroyed"])
        {
            this.cdp.on(event, (parameters) =>
            {
                const info = object(parameters.targetInfo);
                if (event === "Target.targetDestroyed" || info && this.eligible(info))
                    void this.refresh().catch((error) => this.log(error.message));
            });
        }

        await this.cdp.request("Target.setDiscoverTargets", { discover: true });
        await this.refresh();
    }

    get pending(): boolean
    {
        return [...this.sessions].some(([id, session]) =>
            ![...this.byId.values()].includes(session) && Date.now() - this.firstSeen.get(id)! < 3000);
    }

    async settled(): Promise<void>
    {
        await this.refreshing?.catch(() => undefined);
    }

    refresh(): Promise<void>
    {
        this.queued = true;
        this.refreshing ??= (async () =>
        {
            while (this.queued && !this.disabled)
            {
                this.queued = false;
                await this.inspect();
            }
        })().finally(() =>
        {
            this.refreshing = undefined;
        });
        return this.refreshing;
    }

    async install(session: CdpSession): Promise<void>
    {
        const { source, config } = this.payload();
        const current = await installRuntime(session, source, config, (phase, duration) =>
            this.log(`${session.targetId} ${phase}: ${duration.toFixed(1)}ms`));
        if (current)
            this.byId.set(current.windowId, session);

        await this.watches.get(session.targetId)?.();
        this.watches.delete(session.targetId);
        this.log(`Attached ${session.targetId} after ${(performance.now() - this.started).toFixed(1)}ms: ${current?.mode}`);
    }

    async detach(): Promise<void>
    {
        this.disabled = true;
        await this.refreshing?.catch(() => undefined);
        for (const session of this.sessions.values())
        {
            await this.watches.get(session.targetId)?.().catch(() => undefined);
            await session.evaluate("globalThis.__autonomCenter?.dispose();globalThis.__autonomShell?.dispose();"
                + "delete globalThis.__autonomBundle").catch(() => undefined);
            await session.detach();
        }

        this.watches.clear();
        this.sessions.clear();
        this.firstSeen.clear();
        this.byId.clear();
        this.warnings.clear();
    }

    async report(): Promise<unknown>
    {
        const ret = [];
        for (const [targetId, session] of this.sessions)
            ret.push({ targetId, status: await runtimeStatus(session), error: this.warnings.get(targetId) ?? null });

        return { windows: ret };
    }

    private eligible(target: Record<string, unknown>): boolean
    {
        return target.type === "page" && typeof target.url === "string"
            && this.urls.includes(target.url.split(/[?#]/)[0]!);
    }

    private async inspect(): Promise<void>
    {
        const targets = (await this.cdp.targets()).filter((target) => this.eligible(target));
        this.found ||= targets.length > 0;
        if (Date.now() - this.iconsAt >= 5000)
        {
            this.icons = await acpRegistryIcons().catch(() => this.icons);
            this.iconsAt = Date.now();
        }

        for (const [id, session] of this.sessions)
        {
            if (targets.some((target) => target.id === id))
                continue;

            this.sessions.delete(id);
            this.firstSeen.delete(id);
            this.warnings.delete(id);
            await this.watches.get(id)?.().catch(() => undefined);
            this.watches.delete(id);
            for (const [windowId, current] of this.byId)
                if (current === session)
                    this.byId.delete(windowId);

            await session.detach();
        }

        await Promise.all(targets.map(async (target) =>
        {
            try
            {
                let session = this.sessions.get(target.id);
                if (!session)
                {
                    session = await this.cdp.attach(target.id);
                    this.sessions.set(target.id, session);
                    this.firstSeen.set(target.id, Date.now());
                    this.watches.set(target.id, await watchSidebar(session, () =>
                        void this.refresh().catch((error) => this.log(error.message))));
                }

                const { source, config } = this.payload();
                await prepareWindow(session, source, config.content.css ?? "", this.icons);
                const present = await session.evaluate("Boolean(globalThis.__autonomCenter)");
                if (!present)
                    await this.install(session);
                else
                    await session.evaluate("globalThis.__autonomCenter.heartbeat()");

                this.warnings.delete(target.id);
            }
            catch (error)
            {
                const message = error instanceof Error ? error.message : String(error);
                if (this.warnings.get(target.id) !== message)
                    this.log(`${target.id}: ${message}`);

                this.warnings.set(target.id, message);
            }
        }));
    }
}

async function watchSidebar(session: CdpSession, ready: () => void): Promise<() => Promise<void>>
{
    const name = "__autonomSidebarReady";
    const remove = session.on("Runtime.bindingCalled", (parameters) =>
    {
        if (parameters.name === name)
            ready();
    });
    await session.request("Runtime.enable");
    await session.request("Runtime.addBinding", { name });
    await session.evaluate(`(() => {
        let previous;
        const check = () => {
            const current = document.querySelector('[data-slot="sidebar-menu"]');
            if (current && current !== previous) globalThis.${name}("");
            previous = current;
        };
        const observer = new MutationObserver(check);
        observer.observe(document, {childList:true, subtree:true});
        globalThis.__autonomSidebarWatch = observer;
        check();
    })()`);
    return async () =>
    {
        remove();
        await session.evaluate("globalThis.__autonomSidebarWatch?.disconnect();delete globalThis.__autonomSidebarWatch")
            .catch(() => undefined);
        await session.request("Runtime.removeBinding", { name }).catch(() => undefined);
        await session.request("Runtime.disable").catch(() => undefined);
    };
}
