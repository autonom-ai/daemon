import { ActionStore } from "../../../../launcher/center/actions";
import { createPageViews } from "../../../../launcher/patches/center/views";
import { config, testContent } from "../../../support";

import assert from "node:assert/strict";
import { after, test } from "node:test";

const originalFetch = globalThis.fetch;
after(() =>
{
    globalThis.fetch = originalFetch;
});

for (const newer of ["native navigation", "removal", "disposal"])
{
    test(`an unfinished custom page cannot render after ${newer}`, async () =>
    {
        const item = testContent.sections[0]!.items[0]!;
        let respond!: (response: Response) => void;
        globalThis.fetch = () => new Promise<Response>((resolve) => { respond = resolve; });
        const actions = new ActionStore(config().bridge, 2);
        const views = createPageViews((surface) => surface?.id === item.id ? item : undefined,
            actions, () => "demo", () => false);
        const controller = {};
        try
        {
            const pending = views.renderLoaded(controller, {
                id: item.id, path: `/autonom/${item.id}`, label: "Custom", icon: "timer",
            });
            if (newer === "native navigation")
                assert.equal(await views.renderLoaded(controller, { id: "wiki", path: "/wiki", label: "Wiki", icon: "book" }), false);
            else if (newer === "removal")
                views.remove(controller);
            else
                views.dispose();

            respond(Response.json({ result: { type: "html", source: "<h1>Loaded too late</h1>" } }));
            assert.equal(await pending, true);
            assert.equal(views.all.size, 0);
        }
        finally
        {
            views.dispose();
            actions.dispose();
        }
    });
}
