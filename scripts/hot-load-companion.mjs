#!/usr/bin/env node
// Hot-load the current companion build into a live Devin Desktop page without a window reload.
// The companion is imported with a cache-busting query and re-initialized, so UI iterations
// (sidebar rendering, settings, actions) never need a reload. Vendor-bundle hook changes still do.
//
//   node scripts/hot-load-companion.mjs

import { CdpSession } from "./cdp.mjs";

const match = { urlIncludes: process.env.CC_TARGET || "workbench.html" };
const session = await CdpSession.open(match).catch((error) => {
    console.error(error.message);
    process.exit(1);
});

try {
    const result = await session.evaluateFunction(async () => {
        const url = new URL("vs/sessions/autonom.bundle.js", globalThis._VSCODE_FILE_ROOT).href;
        const module = await import(`${url}?v=${Date.now()}`);
        if (typeof module.init !== "function") throw new Error("companion bundle has no init export");
        module.init(globalThis);
        const autonom = globalThis.__autonom ?? {};
        const slots = autonom.slots ?? {};
        return {
            version: autonom.version ?? null,
            api: Object.keys(autonom).filter((key) => typeof autonom[key] === "function").sort(),
            slots: { sidebar: Boolean(slots.sidebar), center: Boolean(slots.center) },
            provider: autonom.provider,
            settingsOpen: typeof autonom.isSettingsOpen === "function" ? autonom.isSettingsOpen() : null,
            errors: Array.isArray(autonom.errors) ? autonom.errors : [],
        };
    });
    console.log(JSON.stringify(result, null, 2));
} catch (error) {
    console.error(error.message);
    process.exit(1);
} finally {
    session.close();
}
