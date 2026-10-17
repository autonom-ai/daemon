import type { RuntimeConfig } from "./types";

export function validateServices(services: any): void
{
    const { manifest, groups, controller, api, windowId } = services;
    if (!manifest?.getManifest || !manifest?._onDidChangeManifest?.fire || !manifest.onDidChangeManifest
        || !groups?.setActiveNavSurface || !groups?.getActiveNavSurface || !api?.executeCommand
        || !Number.isInteger(windowId) || !controller?.show || !controller?.setVisible
        || !controller?.resetActiveSurface || !controller?.reloadActiveSurface || !controller?._load)
        throw new Error("Unsupported native Command Center service shape.");

}

export function validateConfig(config: RuntimeConfig): void
{
    if (!config?.content || !config.bridge?.url || !config.bridge?.token)
        throw new Error("The Command Center runtime needs content and a bridge endpoint.");

}
