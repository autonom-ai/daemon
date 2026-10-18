import { Patches, type PatchStatus } from "./lifecycle";

const hooks = {
    "acp-icons": ["React ACP provider icon hosts", "ACP session codicons"],
    "mode-switch": [".agent-editor-switch"],
    "command-center.manifest": ["manifest.getManifest"],
    "command-center.navigation": ["surface controller show/reset/reload/load/setVisible"],
    "command-center.pages": ["native webview host", "native shell history/title/route callback"],
    "command-center.sidebar": ["Pages rows", "Spaces groups", "section search"],
    "command-center.runtime": ["window runtime and 30-second lease"],
};
const patches = new Map<keyof typeof hooks, Patches>();
type Report = PatchStatus & { hooks: string[] };

/** One bounded report per native hook module, including its last restoration. */
export function createPatch(name: keyof typeof hooks): Patches
{
    const report = (status: PatchStatus) =>
        console.info("[autonom] patch", JSON.stringify({ ...status, hooks: hooks[name] }));
    const ret = new Patches(name, report);
    patches.set(name, ret);
    report(ret.status());
    return ret;
}

export function patchStatus(): Report[]
{
    return [...patches].map(([name, patch]) => ({ ...patch.status(), hooks: hooks[name] }));
}
