import { PatchManager } from "./host/patch";

import { watch } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import * as vscode from "vscode";

/**
 * Autonom Command Center proof-of-concept extension.
 *
 * Responsibilities:
 *  1. Patch the Devin Desktop vendor bundles with the provider switch and sidebar slot.
 *  2. Keep product.json checksums in sync and record the workbench integrity suppression
 *     state so no "installation appears to be corrupt" notification is raised.
 *  3. Watch the built companion and redeploy it on change so live pages hot-load the new
 *     UI through the version file without a window reload.
 */
export async function activate(context: vscode.ExtensionContext): Promise<void> {
    const patchManager = new PatchManager(context);
    const output = vscode.window.createOutputChannel("Autonom Command Center");
    context.subscriptions.push(output);

    let watching = false;
    let watcher: ReturnType<typeof watch> | undefined;

    function log(message: string): void {
        output.appendLine(`[${new Date().toISOString()}] ${message}`);
    }

    async function suppressIntegrityNotification(): Promise<void> {
        try {
            const productPath = join(vscode.env.appRoot, "product.json");
            const product = JSON.parse(await readFile(productPath, "utf8")) as { commit?: string };
            if (product.commit) {
                await context.globalState.update(
                    "integrityService",
                    JSON.stringify({ dontShowPrompt: true, commit: product.commit }),
                );
                log(`Integrity suppression recorded for commit ${product.commit.slice(0, 12)}`);
            }
        } catch (error) {
            log(`Integrity suppression failed: ${error instanceof Error ? error.message : String(error)}`);
        }
    }

    async function applyPatch(announce: boolean): Promise<void> {
        const result = await patchManager.ensurePatched();
        if (result.error) {
            log(`Patch incomplete: ${result.error}`);
            if (announce) void vscode.window.showErrorMessage(`Autonom patch incomplete: ${result.error}`);
            return;
        }
        log(result.applied ? "Patch applied; companion deployed." : "Patch already current; companion redeployed.");
        if (announce && result.applied) {
            void vscode.window.showInformationMessage("Autonom patch applied. Reload the window to load it.");
        }
    }

    async function hotReloadCompanion(): Promise<void> {
        await patchManager.deployCompanion();
        const version = await patchManager.readCompanionVersion();
        log(`Companion redeployed (hot patch version ${version ?? "unknown"}).`);
    }

    function startCompanionWatcher(): void {
        if (watching) return;
        watching = true;
        const companionDir = context.asAbsolutePath("dist/commandCenter");
        let timer: ReturnType<typeof setTimeout> | undefined;
        const schedule = (): void => {
            if (timer !== undefined) clearTimeout(timer);
            timer = setTimeout(() => {
                void hotReloadCompanion().catch((error) =>
                    log(`Hot patch failed: ${error instanceof Error ? error.message : String(error)}`));
            }, 300);
        };
        try {
            watcher = watch(companionDir, { persistent: false }, schedule);
            watcher?.on("error", () => log("Companion watcher stopped."));
            log("Watching the companion build for hot patches.");
        } catch (error) {
            log(`Companion watcher unavailable: ${error instanceof Error ? error.message : String(error)}`);
        }
        context.subscriptions.push({ dispose: () => { watcher?.close(); if (timer !== undefined) clearTimeout(timer); } });
    }

    context.subscriptions.push(
        vscode.commands.registerCommand("autonom.applyPatch", async () => {
            await applyPatch(true);
        }),
        vscode.commands.registerCommand("autonom.restore", async () => {
            const confirmed = await vscode.window.showWarningMessage(
                "Restore the original Devin Desktop bundles?",
                { modal: true, detail: "This restores pristine vendor files from backups and removes companion assets." },
                "Restore",
            );
            if (confirmed !== "Restore") return;
            const result = await patchManager.restore();
            log(result.restored ? "Restored pristine vendor bundles." : `Restore failed: ${result.error}`);
            if (result.restored) void vscode.window.showInformationMessage("Restored. Reload the window to take effect.");
        }),
        vscode.commands.registerCommand("autonom.status", async () => {
            const status = await patchManager.checkStatus();
            const lines = [
                `App root: ${status.appRoot}`,
                `Patched: ${status.patched ? "YES" : "NO"}`,
                `Writable: ${status.writable ? "YES" : "NO"}`,
                ...(status.bundles ?? []).map((bundle) =>
                    `${bundle.displayName}: patched=${bundle.patched} writable=${bundle.writable} backup=${bundle.hasBackup}`),
            ];
            log(lines.join("\n"));
            output.show(true);
        }),
        vscode.commands.registerCommand("autonom.hotReload", async () => {
            await hotReloadCompanion();
        }),
        { dispose: () => watcher?.close() },
    );

    await suppressIntegrityNotification();
    try {
        await applyPatch(false);
        await hotReloadCompanion();
        startCompanionWatcher();
    } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`Activation failed: ${detail}`);
        void vscode.window.showErrorMessage(`Autonom Command Center unavailable: ${detail}`);
    }
}

export function deactivate(): void {
    // Watchers are disposed through context subscriptions.
}
