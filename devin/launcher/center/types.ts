import type { CenterContent } from "./content";

export type RuntimeConfig = {
    content: CenterContent;
    bridge: { url: string; token: string };
};

export type RuntimeStatus = {
    connected: boolean;
    mode: "autonom" | "devin-cloud";
    enabled: boolean;
    revision: string | null;
    activeItem: string | null;
    windowId: number;
    editorActive: boolean;
    items: { id: string; label: string; path: string }[];
    sections: { id: string; label: string | null; items: string[] }[];
    loadedActions: number;
    compiledScripts: number;
};
