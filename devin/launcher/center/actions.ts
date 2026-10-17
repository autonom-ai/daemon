import type { ActionSource, SidebarItem } from "./content";

export function actionKey(item: SidebarItem): string
{
    const action = item.actions!.left_click;
    return `${action.file}:${action.version}`;
}

export class ActionStore
{
    readonly sources = new Map<string, ActionSource>();
    readonly requests = new Map<string, Promise<ActionSource>>();
    readonly scripts = new Map<string, { version: string; run: (context: any) => Promise<unknown> }>();
    private disposed = false;

    constructor(public bridge: { url: string; token: string }, private readonly windowId: number)
    { }

    async loadPage(item: SidebarItem, revision: string | undefined): Promise<ActionSource>
    {
        const key = actionKey(item);
        let request = this.requests.get(key);
        if (!request)
        {
            request = this.request({ action: "getAction", id: item.id, revision }).then((value) =>
            {
                if (value?.type !== "html" || typeof value.source !== "string")
                    throw new Error("The UI action did not return HTML.");

                if (!this.disposed && this.requests.get(key) === request)
                    this.sources.set(key, value);
                return value as ActionSource;
            });
            this.requests.set(key, request);
        }

        try
        {
            return await request;
        }
        catch (error)
        {
            if (this.requests.get(key) === request)
                this.requests.delete(key);

            throw error;
        }
    }

    async request(message: Record<string, unknown>): Promise<any>
    {
        const response = await fetch(`${this.bridge.url}/request`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-autonom-bridge": this.bridge.token },
            body: JSON.stringify({ ...message, windowId: this.windowId }),
            signal: AbortSignal.timeout(30000),
        });
        const body = await response.json();
        if (!response.ok)
            throw new Error(body?.error || `The Command Center bridge returned HTTP ${response.status}.`);

        return body?.result;
    }


    hasScript(item: SidebarItem | undefined, version: string): boolean
    {
        return item?.actions?.left_click.type === "js" && item.actions.left_click.version === version
            && this.scripts.get(actionKey(item))?.version === version;
    }

    setScript(item: SidebarItem | undefined, version: string, run: (context: any) => Promise<unknown>): void
    {
        const action = item?.actions?.left_click;
        if (this.disposed || action?.type !== "js" || action.version !== version)
            throw new Error("The JS action changed before compilation.");

        this.scripts.set(actionKey(item!), { version, run });
    }

    prune(items: Map<string, SidebarItem>): void
    {
        const keys = new Set([...items.values()].filter((item) => item.actions).map(actionKey));
        for (const key of this.requests.keys())
        {
            if (keys.has(key))
                continue;

            this.requests.delete(key);
            this.sources.delete(key);
        }

        for (const key of this.scripts.keys())
            if (!keys.has(key))
                this.scripts.delete(key);
    }

    dispose(): void
    {
        this.disposed = true;
        this.requests.clear();
        this.sources.clear();
        this.scripts.clear();
    }
}
