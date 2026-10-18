import autonomFillMarkup from "../../../../assets/icons/autonom-fill.svg";
import { acpAgentId, acpRegistryIcons, acpRegistryPath } from "../../acp/registry";
import { iconAsset } from "./assets";

interface CachedIcon
{
    revision: string;
    value?: string;
    expires: number;
}

interface IconBudget
{
    dictionaryBytes: number;
    full: boolean;
}

export const iconCatalogByteLimit = 4 * 1024 * 1024;

const autonomIcon = `data:image/svg+xml;base64,${Buffer.from(autonomFillMarkup).toString("base64")}`;

export class IconCatalog
{
    private readonly cache = new Map<string, CachedIcon>();
    private cacheBytes = 0;
    private readonly warned = new Map<string, string>();
    private icons: Record<string, string> = { [acpAgentId]: autonomIcon };
    private pending: Promise<Record<string, string>> | undefined;

    constructor(private readonly registryPath = acpRegistryPath(),
        private readonly warn: (message: string) => void = () => {})
    {
    }

    snapshot(): Record<string, string>
    {
        return { ...this.icons };
    }

    read(): Promise<Record<string, string>>
    {
        if (!this.pending)
            this.pending = this.refresh().finally(() => this.pending = undefined);
        return this.pending;
    }

    private async refresh(): Promise<Record<string, string>>
    {
        const sources = await acpRegistryIcons(this.registryPath);
        const ret: Record<string, string> = { [acpAgentId]: autonomIcon };
        const active = new Set(Object.values(sources));
        for (const [source, cached] of this.cache)
            if (!active.has(source))
            {
                this.cacheBytes -= this.cachedBytes(source, cached);
                this.cache.delete(source);
            }
        const budget = { dictionaryBytes: Buffer.byteLength(JSON.stringify(ret)), full: false };
        const resolved = new Map<string, string>();
        const pending = new Map<string, Promise<string | undefined>>();
        const entries = Object.entries(sources);
        const signal = AbortSignal.timeout(3000);
        let index = 0;
        const readNext = async (): Promise<void> =>
        {
            while (index < entries.length)
            {
                const [provider, source] = entries[index++]!;
                let value = pending.get(source);
                if (!value)
                {
                    value = this.resolve(source, signal, budget);
                    pending.set(source, value);
                }
                const icon = await value;
                const cost = icon ? Buffer.byteLength(JSON.stringify(provider)) + Buffer.byteLength(JSON.stringify(icon)) + 2 : 0;
                if (icon && budget.dictionaryBytes + cost <= iconCatalogByteLimit)
                {
                    resolved.set(provider, icon);
                    budget.dictionaryBytes += cost;
                    this.warned.delete(provider);
                }
                else
                {
                    budget.full ||= Boolean(icon);
                    if (this.warned.get(provider) !== source)
                    {
                        this.warned.set(provider, source);
                        this.warn(`ACP icon unavailable for provider ${JSON.stringify(provider)}.`);
                    }
                }
            }
        };
        await Promise.all(Array.from({ length: Math.min(entries.length, 4) }, readNext));
        for (const [provider] of entries)
        {
            const icon = resolved.get(provider);
            if (icon)
                Object.defineProperty(ret, provider, { value: icon, enumerable: true, configurable: true });
        }
        for (const provider of this.warned.keys())
            if (!Object.hasOwn(sources, provider))
                this.warned.delete(provider);
        this.icons = ret;
        return ret;
    }

    private cachedBytes(source: string, cached: CachedIcon): number
    {
        return Buffer.byteLength(JSON.stringify([source, cached]));
    }

    private save(source: string, cached: CachedIcon, budget: IconBudget): boolean
    {
        const previous = this.cache.get(source);
        const size = this.cachedBytes(source, cached) - (previous ? this.cachedBytes(source, previous) : 0);
        if (this.cacheBytes + size > iconCatalogByteLimit)
        {
            budget.full = true;
            return false;
        }
        this.cache.set(source, cached);
        this.cacheBytes += size;
        return true;
    }

    private async resolve(source: string, signal: AbortSignal, budget: IconBudget): Promise<string | undefined>
    {
        const previous = this.cache.get(source);
        if (budget.full || previous && previous.expires > Date.now())
            return previous?.value;
        try
        {
            const asset = await iconAsset(source, this.registryPath);
            const cached = this.cache.get(source);
            if (cached && cached.revision === asset.revision && cached.expires > Date.now())
                return cached.value;
            if (cached?.value && !asset.remote && cached.revision === asset.revision)
                return cached.value;
            if (signal.aborted || budget.full)
                return cached?.value;
            const value = await asset.load(signal);
            const cachedIcon = { revision: asset.revision, value, expires: asset.remote ? Date.now() + 300000 : 0 };
            return this.save(source, cachedIcon, budget) ? value : undefined;
        }
        catch
        {
            const cached = this.cache.get(source);
            const next: CachedIcon = { revision: cached?.revision ?? "", expires: Date.now() + 60000 };
            if (cached?.value)
                next.value = cached.value;
            this.save(source, next, budget);
            return next.value;
        }
    }
}
