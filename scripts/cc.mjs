#!/usr/bin/env node
// CLI over scripts/cdp.mjs for quick live checks against Devin Desktop.
//
//   node scripts/cc.mjs targets
//   node scripts/cc.mjs state
//   node scripts/cc.mjs eval "localStorage.getItem('autonom.provider')"
//   node scripts/cc.mjs click "[data-provider='devin-cloud']"
//   node scripts/cc.mjs click-text "Autonom Settings"
//   node scripts/cc.mjs watch [seconds]        # stream console errors/exceptions
//   node scripts/cc.mjs reload

import { CdpSession, listTargets, sleep } from "./cdp.mjs";

const match = { urlIncludes: process.env.CC_TARGET || "workbench.html" };
const [command, ...args] = process.argv.slice(2);

function print(value) {
    console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));
}

async function summarize(session) {
    const state = await session.commandCenterState();
    print({
        provider: state.provider,
        settingsOpen: state.settingsOpen,
        roots: state.roots.length,
        providerButtons: state.providerButtons.length,
        settingsButtons: state.settingsButtons.length,
        settingsLayers: state.settingsLayers.length,
        renderedRoots: state.roots.filter((root) => root.rendered).length,
        renderedProviderButtons: state.providerButtons.filter((button) => button.rendered).length,
    });
}

const session = await CdpSession.open(match).catch((error) => {
    console.error(error.message);
    process.exit(1);
});

try {
    switch (command) {
        case "targets":
            print(await listTargets());
            break;
        case "state":
            print(await session.commandCenterState());
            break;
        case "eval":
            print(await session.evaluate(args.join(" ")));
            break;
        case "click": {
            const rect = await session.clickSelector(args[0]);
            await sleep(400);
            print({ clicked: args[0], rect });
            await summarize(session);
            break;
        }
        case "click-text": {
            const result = await session.clickText(args.join(" "));
            await sleep(400);
            print({ clickedText: args.join(" "), result });
            await summarize(session);
            break;
        }
        case "wait":
            print(await session.waitFor(args.join(" "), { timeout: 8000 }));
            break;
        case "watch": {
            const seconds = Number(args[0] || 5);
            await sleep(seconds * 1000);
            print({ exceptions: session.exceptions, consoleErrors: session.consoleEntries.slice(-20) });
            break;
        }
        case "screenshot": {
            const target = args[0] || "/tmp/autonom-screenshot.png";
            const data = await session.screenshot();
            const { writeFile } = await import("node:fs/promises");
            await writeFile(target, Buffer.from(data, "base64"));
            print(`screenshot written to ${target}`);
            break;
        }
        case "reload":
            await session.reload();
            await sleep(1500);
            print("reloaded");
            break;
        default:
            console.error("usage: cc.mjs <targets|state|eval|click|click-text|wait|watch|reload> [args]");
            process.exit(2);
    }
} catch (error) {
    console.error(error.message);
    process.exit(1);
} finally {
    session.close();
}
