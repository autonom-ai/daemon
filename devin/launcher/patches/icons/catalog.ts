import autonomFillMarkup from "../../../../assets/icons/autonom-fill.svg";
import { acpAgentId, acpRegistryIcons, acpRegistryPath } from "../../acp/registry";
import { iconAsset } from "./assets";

interface CachedIcon
{
    revision: string;
    value?: string;
    expires: number;
}

const autonomIcon = `data:image/svg+xml;base64,${Buffer.from(autonomFillMarkup).toString("base64")}`;

export class IconCatalog
{
    private readonly cache = new Map<string, CachedIcon>();
    private readonly warned = new Map<string, string>();
    private pending: Promise<Record<string, string>> | undefined;

    constructor(private readonly registryPath = acpRegistryPath(),
        private readonly warn: (message: string) => void = () => {})
    {
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
        const retained = new Set<string>();
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
                    value = this.resolve(source, retained, signal);
                    pending.set(source, value);
                }
                const icon = await value;
                if (icon)
                {
                    Object.defineProperty(ret, provider, { value: icon, enumerable: true, configurable: true });
                    this.warned.delete(provider);
                }
                else if (this.warned.get(provider) !== source)
                {
                    this.warned.set(provider, source);
                    this.warn(`ACP icon unavailable for provider ${JSON.stringify(provider)}.`);
                }
            }
        };
        await Promise.all(Array.from({ length: Math.min(entries.length, 4) }, readNext));
        for (const key of this.cache.keys())
            if (!retained.has(key))
                this.cache.delete(key);
        for (const provider of this.warned.keys())
            if (!Object.hasOwn(sources, provider))
                this.warned.delete(provider);
        return ret;
    }

    private async resolve(source: string, retained: Set<string>, signal: AbortSignal): Promise<string | undefined>
    {
        retained.add(source);
        const previous = this.cache.get(source);
        if (previous && previous.expires > Date.now())
            return previous.value;
        try
        {
            const asset = await iconAsset(source, this.registryPath);
            const cached = this.cache.get(source);
            if (cached && cached.revision === asset.revision && cached.expires > Date.now())
                return cached.value;
            if (cached?.value && !asset.remote && cached.revision === asset.revision)
                return cached.value;
            if (signal.aborted)
                return cached?.value;
            const value = await asset.load(signal);
            this.cache.set(source, { revision: asset.revision, value, expires: asset.remote ? Date.now() + 300000 : 0 });
            return value;
        }
        catch
        {
            const cached = this.cache.get(source);
            const next: CachedIcon = { revision: cached?.revision ?? "", expires: Date.now() + 60000 };
            if (cached?.value)
                next.value = cached.value;
            this.cache.set(source, next);
            return next.value;
        }
    }
}
