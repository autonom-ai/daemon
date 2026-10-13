/**
 * Autonom Command Center PoC companion.
 *
 * The companion owns only the Autonom sidebar pane. The provider switch, the React-owned
 * sidebar slot, provider persistence, and the CSS that hides native Devin content live in
 * the injected bootstrap; this module fills the slot and re-renders on provider changes and
 * on hot-patch reloads.
 */

export interface AutonomCommandCenterState {
    version: number;
    provider: string;
    isAutonomActive(): boolean;
    setProvider(provider: string): void;
    subscribe(callback: (provider: string) => void): () => void;
    onSlots(callback: (slots: { sidebar: HTMLElement | null }) => void): () => void;
    sidebarSlot(element: HTMLElement | null): void;
}

const memoryStorage = new Map<string, string>();
const subscribers = new Set<(provider: string) => void>();
let sidebarSlotElement: HTMLElement | null = null;

function safeGetItem(key: string, fallback: string): string {
    try {
        if (typeof localStorage !== "undefined" && localStorage !== null) {
            const value = localStorage.getItem(key);
            if (value !== null) return value;
        }
    } catch {}
    return memoryStorage.get(key) ?? fallback;
}

function safeSetItem(key: string, value: string): void {
    try {
        if (typeof localStorage !== "undefined" && localStorage !== null) {
            localStorage.setItem(key, value);
        }
    } catch {}
    memoryStorage.set(key, value);
}

function createElement<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    className = "",
    label?: string,
): HTMLElementTagNameMap[K] {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (label !== undefined) element.textContent = label;
    return element;
}

function isAutonomActive(): boolean {
    return safeGetItem("autonom.provider", "autonom") !== "devin-cloud";
}

function setProvider(provider: string): void {
    const value = provider === "devin-cloud" ? "devin-cloud" : "autonom";
    safeSetItem("autonom.provider", value);
    if (typeof document !== "undefined") {
        document.documentElement.dataset.autonomProvider = value;
        for (const segment of document.querySelectorAll<HTMLElement>("[data-provider]")) {
            const active = segment.getAttribute("data-provider") === value;
            segment.classList.toggle("active", active);
            segment.setAttribute("aria-pressed", String(active));
        }
    }
    for (const callback of subscribers) {
        try {
            callback(value);
        } catch {}
    }
    if (typeof window !== "undefined") {
        window.dispatchEvent(new CustomEvent("autonom:provider-changed", { detail: { provider: value } }));
    }
    renderSidebar();
}

function appendGroup(parent: HTMLElement, title: string, rows: HTMLElement[]): void {
    const group = createElement("div", "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1");
    group.setAttribute("data-slot", "sidebar-group");
    group.setAttribute("data-autonom-tier", title.toLowerCase());
    const heading = createElement("div", "group/sidebar-label-row flex h-7 shrink-0 items-center justify-between gap-px pl-2 pr-1");
    heading.setAttribute("data-slot", "sidebar-label-row");
    heading.appendChild(createElement(
        "div",
        "text-11 uppercase tracking-wider text-text-secondary flex items-center rounded-md font-semibold flex-1",
        title,
    ));
    group.appendChild(heading);
    const list = createElement("ul", "flex w-full min-w-0 flex-col py-0.5");
    list.setAttribute("data-slot", "sidebar-menu");
    for (const row of rows) {
        const item = createElement("li", "group/menu-item relative isolate mb-0.5");
        item.setAttribute("data-slot", "sidebar-menu-item");
        item.appendChild(row);
        list.appendChild(item);
    }
    group.appendChild(list);
    parent.appendChild(group);
}

function renderSidebar(): void {
    if (typeof document === "undefined") return;
    const slot = sidebarSlotElement;
    if (!slot) return;
    slot.replaceChildren();
    const root = createElement("div", "command-center-sidebar-root flex flex-col w-full");
    root.setAttribute("data-autonom-root", "sidebar");

    const active = isAutonomActive();
    const rows: HTMLElement[] = [];
    const status = createElement(
        "div",
        "command-center-row text-12 text-text-secondary px-2 py-1",
        active ? "Autonom mode · native session list hidden" : "Devin Cloud mode · native session list visible",
    );
    rows.push(status);
    appendGroup(root, "Autonom", rows);
    slot.appendChild(root);
}

export function init(target: any = globalThis): AutonomCommandCenterState {
    const autonom = target.__autonom || {};
    autonom.provider = safeGetItem("autonom.provider", "autonom");
    autonom.isAutonomActive = isAutonomActive;
    autonom.setProvider = setProvider;
    autonom.subscribe = (callback: (provider: string) => void): (() => void) => {
        subscribers.add(callback);
        return () => subscribers.delete(callback);
    };
    target.__autonom = autonom;
    if (typeof autonom.onSlots === "function") {
        autonom.onSlots((slots: { sidebar: HTMLElement | null }) => {
            sidebarSlotElement = slots.sidebar ?? null;
            renderSidebar();
        });
    }
    setProvider(safeGetItem("autonom.provider", "autonom"));
    return autonom as AutonomCommandCenterState;
}

if (typeof globalThis !== "undefined") init(globalThis);
