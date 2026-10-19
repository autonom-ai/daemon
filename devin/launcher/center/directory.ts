export type DirectoryEntry = { name: string; icon?: string };

/** Cached daemon listings; refresh never holds up native sidebar attachment. */
export class Directory
{
    private readonly listings = new Map<string, DirectoryEntry[]>();
    private pending: Promise<void> | undefined;
    private refreshed = 0;
    private disposed = false;

    constructor(
        private readonly request: (message: Record<string, unknown>) => Promise<unknown>,
        private readonly changed: () => void,
    )
    { }

    entries(section: string): readonly DirectoryEntry[]
    {
        return this.listings.get(section) ?? [];
    }

    refresh(): void
    {
        if (this.disposed || this.pending || Date.now() - this.refreshed < 5000)
            return;

        this.refreshed = Date.now();
        this.pending = Promise.all([
            this.load("rooms", "getRooms", "hash"),
            this.load("profiles", "getProfiles"),
        ]).then(() => undefined).finally(() =>
        {
            this.pending = undefined;
        });
    }

    dispose(): void
    {
        this.disposed = true;
        this.listings.clear();
    }

    private async load(section: string, action: string, icon?: string): Promise<void>
    {
        try
        {
            const response = await this.request({ action });
            if (!Array.isArray(response) || response.some((entry) => typeof entry?.name !== "string"))
                throw new Error(`The daemon returned an invalid ${section} listing.`);

            if (this.disposed)
                return;

            const entries: DirectoryEntry[] = response.map((entry) => icon
                ? { name: entry.name, icon }
                : { name: entry.name });
            entries.sort((left, right) => left.name.localeCompare(right.name));
            if (JSON.stringify(entries) === JSON.stringify(this.entries(section)))
                return;

            this.listings.set(section, entries);
            this.changed();
        }
        catch (error)
        {
            if (!this.disposed)
                console.error(`[autonom] Could not refresh ${section}`, error);
        }
    }
}
