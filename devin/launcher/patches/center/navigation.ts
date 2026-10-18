import type { NativeItem } from "../../center/content";
import { createPatch } from "../status";
import type { createPageViews } from "./views";

export function patchNavigation(controller: any, views: ReturnType<typeof createPageViews>)
{
    const patches = createPatch("command-center.navigation");
    try
    {
        const show = controller.show;
        patches.wrap(controller, "show", async function (this: any, surface: NativeItem): Promise<void>
        {
            if (await views.renderLoaded(this, surface))
                return;

            views.remove(this);
            return show.call(this, surface);
        });
        for (const name of ["resetActiveSurface", "reloadActiveSurface", "_load", "_remountAndLoad"])
        {
            const original = controller[name];
            if (typeof original !== "function")
                continue;

            patches.wrap(controller, name, async function (this: any, ...args: unknown[]): Promise<unknown>
            {
                if (await views.renderLoaded(this, views.all.get(this)?.surface ?? this._currentSurface))
                    return;

                return original.apply(this, args);
            });
        }

        const setVisible = controller.setVisible;
        patches.wrap(controller, "setVisible", function (this: any, visible: boolean): void
        {
            setVisible.call(this, visible);
            const view = views.all.get(this);
            if (view)
                view.host.hidden = !visible;
        });
        return patches;
    }
    catch (error)
    {
        patches.restore();
        throw error;
    }
}
