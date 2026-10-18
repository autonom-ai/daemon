import type { CenterContent, NativeItem } from "./content";
import { spacesSection } from "./content";
import type { RuntimeStatus } from "./types";

export function runtimeSnapshot(context: {
    disposed: boolean;
    mode: "autonom" | "devin-cloud";
    content: CenterContent;
    activeItem: string | null;
    windowId: number;
    editorActive: boolean;
    manifest: { items: NativeItem[] };
    loadedActions: number;
    compiledScripts: number;
}): RuntimeStatus
{
    const { content, mode, windowId } = context;
    return {
        connected: !context.disposed,
        mode,
        enabled: content.enabled && mode === "autonom",
        revision: content.revision ?? null,
        activeItem: context.activeItem,
        windowId,
        editorActive: context.editorActive,
        items: context.manifest.items.map((item: NativeItem) =>
        {
            return { id: item.id, label: item.label, path: item.path };
        }),
        sections: content.sections.map((section) => ({
            id: section.id,
            label: section.label ?? null,
            items: section.items.filter((item) => !item.hidden).map((item) => item.id),
            buttons: (section.buttons ?? []).filter((button) => !button.hidden).map((button) => button.id),
        })),
        spaces: !(content.enabled && mode === "autonom")
            || Boolean(content.devinCloud?.includes(spacesSection)),
        loadedActions: context.loadedActions,
        compiledScripts: context.compiledScripts,
    };
}
