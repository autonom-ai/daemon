import type { NativeItem } from "../../center/content";
import { Patches, restorePatches } from "../lifecycle";

/** The pinned shell derives its native header/history from this borrowed state. */
export class NativeHistory
{
    private readonly patches = new Patches("command-center.history");

    constructor(private readonly shell: any)
    {
        try
        {
            this.patches.wrap(shell, "_onActiveRoute", function (): void {});
            this.patches.style(shell._mountEl, "visibility", "hidden");
        }
        catch (error)
        {
            this.patches.restore();
            throw error;
        }
    }

    show(surface: NativeItem, title: string): void
    {
        this.patches.set(this.shell, "_activeSurfaceId", surface.id);
        this.patches.map(this.shell._surfaces, surface.id, {
            stack: [surface.path], cursor: 0, lastRouteCategory: undefined,
        });
        this.patches.set(this.shell, "_title", title);
        this.patches.set(this.shell, "_activeSidebar", undefined);
        this.shell._reportState();
    }

    restore(): boolean
    {
        try
        {
            return restorePatches([this.patches]);
        }
        finally
        {
            this.shell._reportState();
        }
    }
}
