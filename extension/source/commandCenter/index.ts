/**
 * Autonom Devin Desktop Command Center Companion Bundle
 * Deployed to:
 * - out/vs/workbench/windsurf-chat-client/autonom.bundle.js
 * - out/vs/sessions/autonom.bundle.js
 *
 * Strictly respects Trusted Types: zero raw innerHTML string assignments.
 */

import { fnv1a, IDENTICON_PALETTE } from "../webview/identicon";

export interface AutonomCommandCenterState {
    provider: string;
    isAutonomActive(): boolean;
    setProvider(provider: string): void;
    subscribe(callback: (provider: string) => void): () => void;
    wrapNewSession(jsxRuntime?: any): (type: any, props: any, key?: any) => any;
    renderSidebar(jsxRuntime?: any): any;
    renderCenter(jsxRuntime?: any): any;
    mountSidebar(container: HTMLElement): HTMLElement | null;
}

const memoryStorage = new Map<string, string>();

function safeGetItem(key: string, fallback: string): string {
    try {
        if (typeof localStorage !== "undefined" && localStorage !== null) {
            const val = localStorage.getItem(key);
            if (val !== null) return val;
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

/**
 * Creates a Trusted-Types safe 5x5 symmetric SVG identicon DOM node
 */
export function createIdenticonElement(name: string, size = 18): SVGSVGElement {
    const hash = fnv1a((name || "autonom").trim().toLowerCase());
    const color = IDENTICON_PALETTE[hash % IDENTICON_PALETTE.length] || "var(--vscode-charts-blue)";
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", String(size));
    svg.setAttribute("height", String(size));
    svg.setAttribute("viewBox", "0 0 5 5");
    svg.setAttribute("shape-rendering", "crispEdges");
    svg.setAttribute("aria-hidden", "true");
    svg.classList.add("shrink-0", "rounded-[3px]");

    let count = 0;
    for (let c = 0; c < 3; c++) {
        for (let r = 0; r < 5; r++) {
            const bit = (hash >>> (c * 5 + r)) & 1;
            if (bit === 1) {
                const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
                rect.setAttribute("x", String(c));
                rect.setAttribute("y", String(r));
                rect.setAttribute("width", "1");
                rect.setAttribute("height", "1");
                rect.setAttribute("fill", color);
                svg.appendChild(rect);
                count++;
                if (c < 2) {
                    const mirror = document.createElementNS("http://www.w3.org/2000/svg", "rect");
                    mirror.setAttribute("x", String(4 - c));
                    mirror.setAttribute("y", String(r));
                    mirror.setAttribute("width", "1");
                    mirror.setAttribute("height", "1");
                    mirror.setAttribute("fill", color);
                    svg.appendChild(mirror);
                    count++;
                }
            }
        }
    }
    if (count === 0) {
        const center = document.createElementNS("http://www.w3.org/2000/svg", "rect");
        center.setAttribute("x", "2");
        center.setAttribute("y", "2");
        center.setAttribute("width", "1");
        center.setAttribute("height", "1");
        center.setAttribute("fill", color);
        svg.appendChild(center);
    }
    return svg;
}

/**
 * Creates React JSX identicon element
 */
export function createIdenticonJsx(name: string, r: any, size = 18): any {
    const hash = fnv1a((name || "autonom").trim().toLowerCase());
    const color = IDENTICON_PALETTE[hash % IDENTICON_PALETTE.length] || "var(--vscode-charts-blue)";
    const rects: any[] = [];
    for (let c = 0; c < 3; c++) {
        for (let row = 0; row < 5; row++) {
            const bit = (hash >>> (c * 5 + row)) & 1;
            if (bit === 1) {
                rects.push(r.jsx("rect", { key: `r_${c}_${row}`, x: c, y: row, width: 1, height: 1, fill: color }));
                if (c < 2) {
                    rects.push(r.jsx("rect", { key: `m_${4 - c}_${row}`, x: 4 - c, y: row, width: 1, height: 1, fill: color }));
                }
            }
        }
    }
    if (rects.length === 0) {
        rects.push(r.jsx("rect", { key: "c_2_2", x: 2, y: 2, width: 1, height: 1, fill: color }));
    }
    return r.jsx("svg", {
        width: size,
        height: size,
        viewBox: "0 0 5 5",
        "shape-rendering": "crispEdges",
        "aria-hidden": "true",
        className: "shrink-0 rounded-[3px]",
        children: rects,
    });
}

/**
 * Native DOM Provider Toggle & Sidebar Controller for direct element mounting.
 * Strictly Trusted Types compliant: zero innerHTML assignments.
 */
export class ProviderToggleController {
    private isAutonom: boolean;
    private toggleElement: HTMLElement | null = null;
    private sidebarContainer: HTMLElement | null = null;

    public get element(): HTMLElement | null {
        return this.toggleElement;
    }

    public get sidebar(): HTMLElement | null {
        return this.sidebarContainer;
    }

    constructor() {
        this.isAutonom = safeGetItem("autonom.provider", "autonom") !== "devin-cloud";
    }

    public setProvider(next: "autonom" | "devin-cloud", notify = true): void {
        this.isAutonom = next === "autonom";
        safeSetItem("autonom.provider", next);

        // Update active switch segments in DOM
        if (typeof document !== "undefined") {
            const autonomSegments = document.querySelectorAll<HTMLElement>("[data-provider='autonom']");
            const cloudSegments = document.querySelectorAll<HTMLElement>("[data-provider='devin-cloud']");

            autonomSegments.forEach((el) => {
                el.classList.toggle("active", this.isAutonom);
                el.setAttribute("data-active", String(this.isAutonom));
            });
            cloudSegments.forEach((el) => {
                el.classList.toggle("active", !this.isAutonom);
                el.setAttribute("data-active", String(!this.isAutonom));
            });

            // Live DOM Visibility Switch (Instant, Zero Reload)
            const autonomSidebarSections = document.querySelectorAll<HTMLElement>("[data-autonom-tier]");
            const cloudSpacesGroups = document.querySelectorAll<HTMLElement>("[data-slot='sidebar-group']:not([data-autonom-tier]), .command-center-cloud");

            autonomSidebarSections.forEach((el) => { el.hidden = !this.isAutonom; });
            cloudSpacesGroups.forEach((el) => { el.hidden = this.isAutonom; });
        }

        if (notify && typeof window !== "undefined") {
            window.dispatchEvent(new CustomEvent("autonom:provider-changed", {
                detail: { provider: next },
            }));
        }
    }

    /**
     * Mounts the native 2-segment pill switch [ Autonom | Devin Cloud ]
     * using .switch-container and .switch-segment directly above "+ New session".
     */
    public mount(containerUl: HTMLElement): HTMLElement {
        const li = document.createElement("li");
        li.setAttribute("data-slot", "sidebar-menu-item");
        li.className = "group/menu-item relative isolate mb-2 mt-1";

        const switchDiv = document.createElement("div");
        switchDiv.className = "switch-container group/switch relative flex w-full p-0.5 rounded-[7px] bg-tint-secondary items-center h-[28px] box-border mb-1";
        switchDiv.style.backgroundColor = "rgb(var(--tint-secondary, 255 255 255 / 0.06))";
        switchDiv.style.border = "1px solid rgb(var(--border-secondary, 255 255 255 / 0.08))";

        const autonomBtn = document.createElement("button");
        autonomBtn.type = "button";
        autonomBtn.setAttribute("data-provider", "autonom");
        autonomBtn.className = `switch-segment ${this.isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all`;
        autonomBtn.textContent = "Autonom";
        autonomBtn.addEventListener("click", () => this.setProvider("autonom"));

        const cloudBtn = document.createElement("button");
        cloudBtn.type = "button";
        cloudBtn.setAttribute("data-provider", "devin-cloud");
        cloudBtn.className = `switch-segment ${!this.isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all`;
        cloudBtn.textContent = "Devin Cloud";
        cloudBtn.addEventListener("click", () => this.setProvider("devin-cloud"));

        switchDiv.appendChild(autonomBtn);
        switchDiv.appendChild(cloudBtn);
        li.appendChild(switchDiv);

        this.toggleElement = li;

        if (containerUl.firstElementChild) {
            containerUl.insertBefore(li, containerUl.firstElementChild);
        } else {
            containerUl.appendChild(li);
        }

        return li;
    }

    /**
     * Mounts the full 3-Tier sidebar into the sidebar rail.
     * Strictly Trusted Types compliant.
     */
    public mountSidebar(railAside: HTMLElement): HTMLElement {
        // Remove existing mount if present
        const existing = railAside.querySelector<HTMLElement>(".command-center-sidebar-root");
        if (existing) {
            existing.remove();
        }

        const root = document.createElement("div");
        root.className = "command-center-sidebar-root flex flex-col w-full";
        root.hidden = !this.isAutonom;

        // TIER 1: Coordination Rooms
        const roomsGroup = document.createElement("div");
        roomsGroup.setAttribute("data-slot", "sidebar-group");
        roomsGroup.setAttribute("data-autonom-tier", "rooms");
        roomsGroup.className = "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1";

        const roomsHeader = document.createElement("div");
        roomsHeader.setAttribute("data-slot", "sidebar-label-row");
        roomsHeader.className = "group/sidebar-label-row flex h-7 shrink-0 items-center justify-between gap-px pl-2 pr-1 static z-auto bg-transparent";

        const roomsLabel = document.createElement("div");
        roomsLabel.setAttribute("data-slot", "sidebar-group-label");
        roomsLabel.className = "text-11 uppercase tracking-wider text-text-secondary flex items-center rounded-md font-semibold flex-1";
        roomsLabel.textContent = "Coordination Rooms";

        const roomAddBtn = document.createElement("button");
        roomAddBtn.type = "button";
        roomAddBtn.className = "inline-flex items-center justify-center size-5 rounded hover:bg-tint-secondary text-text-secondary hover:text-text-primary cursor-pointer";
        roomAddBtn.textContent = "+";
        roomAddBtn.title = "Create room";

        roomsHeader.appendChild(roomsLabel);
        roomsHeader.appendChild(roomAddBtn);
        roomsGroup.appendChild(roomsHeader);

        const roomsUl = document.createElement("ul");
        roomsUl.setAttribute("data-slot", "sidebar-menu");
        roomsUl.className = "flex w-full min-w-0 flex-col py-0.5";

        // Room 1: #general with unread badge 3 (auto-clears on click)
        const roomGeneral = this.createRoomMenuItem("general", 3);
        const roomSecurity = this.createRoomMenuItem("security-review", 0);
        roomsUl.appendChild(roomGeneral);
        roomsUl.appendChild(roomSecurity);
        roomsGroup.appendChild(roomsUl);

        // TIER 2: Agent Profiles
        const profilesGroup = document.createElement("div");
        profilesGroup.setAttribute("data-slot", "sidebar-group");
        profilesGroup.setAttribute("data-autonom-tier", "profiles");
        profilesGroup.className = "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1";

        const profilesHeader = document.createElement("div");
        profilesHeader.setAttribute("data-slot", "sidebar-label-row");
        profilesHeader.className = "group/sidebar-label-row flex h-7 shrink-0 items-center justify-between gap-px pl-2 pr-1 static z-auto bg-transparent";

        const profilesLabel = document.createElement("div");
        profilesLabel.setAttribute("data-slot", "sidebar-group-label");
        profilesLabel.className = "text-11 uppercase tracking-wider text-text-secondary flex items-center rounded-md font-semibold flex-1";
        profilesLabel.textContent = "Agent Profiles";

        profilesHeader.appendChild(profilesLabel);
        profilesGroup.appendChild(profilesHeader);

        const profilesUl = document.createElement("ul");
        profilesUl.setAttribute("data-slot", "sidebar-menu");
        profilesUl.className = "flex w-full min-w-0 flex-col py-0.5";

        // Profiles: architect (running, green), sentry (idle, yellow), reviewer (offline, gray)
        profilesUl.appendChild(this.createProfileMenuItem("architect", "running", "Session 3fe9694e (swe-2-medium)"));
        profilesUl.appendChild(this.createProfileMenuItem("sentry", "idle"));
        profilesUl.appendChild(this.createProfileMenuItem("reviewer", "offline"));
        profilesGroup.appendChild(profilesUl);

        // TIER 3: Unassigned Sessions
        const unassignedGroup = document.createElement("div");
        unassignedGroup.setAttribute("data-slot", "sidebar-group");
        unassignedGroup.setAttribute("data-autonom-tier", "unassigned");
        unassignedGroup.className = "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1";

        const unassignedHeader = document.createElement("div");
        unassignedHeader.setAttribute("data-slot", "sidebar-label-row");
        unassignedHeader.className = "group/sidebar-label-row flex h-7 shrink-0 items-center justify-between gap-px pl-2 pr-1 static z-auto bg-transparent";

        const unassignedLabel = document.createElement("div");
        unassignedLabel.setAttribute("data-slot", "sidebar-group-label");
        unassignedLabel.className = "text-11 uppercase tracking-wider text-text-secondary flex items-center rounded-md font-semibold flex-1";
        unassignedLabel.textContent = "Unassigned Sessions";

        const unassignedAddBtn = document.createElement("button");
        unassignedAddBtn.type = "button";
        unassignedAddBtn.className = "inline-flex items-center justify-center size-5 rounded hover:bg-tint-secondary text-text-secondary hover:text-text-primary cursor-pointer";
        unassignedAddBtn.textContent = "+";
        unassignedAddBtn.title = "New unassigned session";

        unassignedHeader.appendChild(unassignedLabel);
        unassignedHeader.appendChild(unassignedAddBtn);
        unassignedGroup.appendChild(unassignedHeader);

        const unassignedUl = document.createElement("ul");
        unassignedUl.setAttribute("data-slot", "sidebar-menu");
        unassignedUl.className = "flex w-full min-w-0 flex-col py-0.5";

        unassignedUl.appendChild(this.createSessionMenuItem("Fix compiler flags", "running"));
        unassignedUl.appendChild(this.createSessionMenuItem("Explore repository layout", "offline"));
        unassignedGroup.appendChild(unassignedUl);

        // TIER 4: Settings
        const settingsGroup = document.createElement("div");
        settingsGroup.setAttribute("data-slot", "sidebar-group");
        settingsGroup.setAttribute("data-autonom-tier", "settings");
        settingsGroup.className = "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pt-2 mt-auto border-t border-border-secondary";
        settingsGroup.style.marginTop = "auto";
        settingsGroup.style.borderTop = "1px solid var(--vscode-widget-border, rgba(255,255,255,0.08))";

        const settingsUl = document.createElement("ul");
        settingsUl.setAttribute("data-slot", "sidebar-menu");
        settingsUl.className = "flex w-full min-w-0 flex-col py-0.5";

        const settingsLi = document.createElement("li");
        settingsLi.setAttribute("data-slot", "sidebar-menu-item");
        settingsLi.className = "group/menu-item relative isolate mb-0.5";

        const settingsBtn = document.createElement("div");
        settingsBtn.id = "autonom-settings-btn";
        settingsBtn.setAttribute("data-slot", "sidebar-menu-button");
        settingsBtn.className = "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] cursor-pointer hover:bg-tint-secondary text-13 text-text-secondary hover:text-text-primary";

        const gearSpan = document.createElement("span");
        gearSpan.className = "text-14";
        gearSpan.textContent = "⚙";

        const labelSpan = document.createElement("span");
        labelSpan.className = "flex-1 font-medium";
        labelSpan.textContent = "Autonom Settings";

        settingsBtn.appendChild(gearSpan);
        settingsBtn.appendChild(labelSpan);
        settingsBtn.addEventListener("click", () => {
            (globalThis as any).__autonom?.openSettings?.();
        });

        settingsLi.appendChild(settingsBtn);
        settingsUl.appendChild(settingsLi);
        settingsGroup.appendChild(settingsUl);

        root.appendChild(roomsGroup);
        root.appendChild(profilesGroup);
        root.appendChild(unassignedGroup);
        root.appendChild(settingsGroup);

        this.sidebarContainer = root;

        // Insert directly after sidebar-header or prepend
        const header = railAside.querySelector("[data-slot='sidebar-header']");
        if (header && header.nextSibling) {
            railAside.insertBefore(root, header.nextSibling);
        } else {
            railAside.appendChild(root);
        }

        return root;
    }

    private createRoomMenuItem(name: string, unreadCount: number): HTMLElement {
        const li = document.createElement("li");
        li.setAttribute("data-slot", "sidebar-menu-item");
        li.className = "group/menu-item relative isolate mb-0.5";

        const btn = document.createElement("div");
        btn.setAttribute("data-slot", "sidebar-menu-button");
        btn.className = "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] cursor-pointer hover:bg-tint-secondary text-13 text-text-primary";

        const hashSpan = document.createElement("span");
        hashSpan.className = "text-text-secondary font-mono text-12";
        hashSpan.textContent = "#";

        const nameSpan = document.createElement("span");
        nameSpan.className = "flex-1 truncate font-medium";
        nameSpan.textContent = name;

        btn.appendChild(hashSpan);
        btn.appendChild(nameSpan);

        let badge: HTMLElement | null = null;
        if (unreadCount > 0) {
            badge = document.createElement("span");
            badge.className = "unread-badge inline-flex items-center justify-center min-w-[18px] h-4 px-1.5 rounded-full text-11 font-semibold bg-tint-secondary text-text-primary";
            badge.textContent = String(unreadCount);
            btn.appendChild(badge);
        }

        // Auto-clear unread badge upon opening/selection
        btn.addEventListener("click", () => {
            if (badge) {
                badge.remove();
                badge = null;
            }
            if (typeof window !== "undefined") {
                window.dispatchEvent(new CustomEvent("autonom:room-selected", { detail: { room: name } }));
            }
        });

        li.appendChild(btn);
        return li;
    }

    private createProfileMenuItem(name: string, status: "running" | "idle" | "offline", subSession?: string): HTMLElement {
        const li = document.createElement("li");
        li.setAttribute("data-slot", "sidebar-menu-item");
        li.className = "group/menu-item relative isolate mb-0.5";

        const btn = document.createElement("div");
        btn.setAttribute("data-slot", "sidebar-menu-button");
        btn.className = "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] cursor-pointer hover:bg-tint-secondary text-13 text-text-primary";

        // Deterministic 5x5 SVG identicon
        const identiconEl = createIdenticonElement(name, 18);
        btn.appendChild(identiconEl);

        const nameSpan = document.createElement("span");
        nameSpan.className = "flex-1 truncate font-medium";
        nameSpan.textContent = name;
        btn.appendChild(nameSpan);

        // Status dot: green=running, yellow=idle, gray=offline
        const dot = document.createElement("span");
        dot.className = "status-dot inline-block size-2 rounded-full shrink-0";
        if (status === "running") {
            dot.style.backgroundColor = "var(--vscode-charts-green, #82c5a5)";
            dot.style.boxShadow = "0 0 6px rgba(130,197,165,0.4)";
            dot.title = "Running";
        } else if (status === "idle") {
            dot.style.backgroundColor = "var(--vscode-charts-yellow, #d9b981)";
            dot.title = "Idle";
        } else {
            dot.style.backgroundColor = "var(--vscode-disabledForeground, rgba(255,255,255,0.3))";
            dot.title = "Offline";
        }
        btn.appendChild(dot);
        li.appendChild(btn);

        if (subSession) {
            const subDiv = document.createElement("div");
            subDiv.className = "flex items-center gap-1.5 pl-7 pr-2 py-0.5 text-11 text-text-secondary truncate";
            subDiv.textContent = `↳ ${subSession}`;
            li.appendChild(subDiv);
        }

        return li;
    }

    private createSessionMenuItem(title: string, status: "running" | "offline"): HTMLElement {
        const li = document.createElement("li");
        li.setAttribute("data-slot", "sidebar-menu-item");
        li.className = "group/menu-item relative isolate mb-0.5";

        const btn = document.createElement("div");
        btn.setAttribute("data-slot", "sidebar-menu-button");
        btn.className = "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] cursor-pointer hover:bg-tint-secondary text-13 text-text-primary";

        const iconSpan = document.createElement("span");
        iconSpan.className = "text-text-secondary text-12";
        iconSpan.textContent = "💬";

        const nameSpan = document.createElement("span");
        nameSpan.className = "flex-1 truncate";
        nameSpan.textContent = title;

        btn.appendChild(iconSpan);
        btn.appendChild(nameSpan);

        const dot = document.createElement("span");
        dot.className = "status-dot inline-block size-2 rounded-full shrink-0";
        if (status === "running") {
            dot.style.backgroundColor = "var(--vscode-charts-green, #82c5a5)";
            dot.style.boxShadow = "0 0 6px rgba(130,197,165,0.4)";
            dot.title = "Running";
        } else {
            dot.style.backgroundColor = "var(--vscode-disabledForeground, rgba(255,255,255,0.3))";
            dot.title = "Offline";
        }
        btn.appendChild(dot);

        li.appendChild(btn);
        return li;
    }
}

export function init(target: any = globalThis): AutonomCommandCenterState {
    const autonom = target.__autonom || {};
    const subscribers = new Set<(provider: string) => void>();
    const controller = new ProviderToggleController();

    autonom.isAutonomActive = function (): boolean {
        return safeGetItem("autonom.provider", "autonom") !== "devin-cloud";
    };

    autonom.setProvider = function (next: string): void {
        const val = next === "devin-cloud" ? "devin-cloud" : "autonom";
        safeSetItem("autonom.provider", val);
        const isAutonom = val === "autonom";

        for (const cb of subscribers) {
            try { cb(val); } catch {}
        }

        if (typeof window !== "undefined") {
            window.dispatchEvent(new CustomEvent("autonom:provider-changed", { detail: { provider: val } }));
        }

        // Live DOM Visibility Switch without reload
        if (typeof document !== "undefined") {
            const autonomSegments = document.querySelectorAll<HTMLElement>("[data-provider='autonom']");
            const cloudSegments = document.querySelectorAll<HTMLElement>("[data-provider='devin-cloud']");

            autonomSegments.forEach((el) => {
                el.classList.toggle("active", isAutonom);
                el.setAttribute("data-active", String(isAutonom));
            });
            cloudSegments.forEach((el) => {
                el.classList.toggle("active", !isAutonom);
                el.setAttribute("data-active", String(!isAutonom));
            });

            const autonomSidebarSections = document.querySelectorAll<HTMLElement>("[data-autonom-tier], .command-center-sidebar-root");
            const cloudSpacesGroups = document.querySelectorAll<HTMLElement>("[data-slot='sidebar-group']:not([data-autonom-tier]), .command-center-cloud");

            autonomSidebarSections.forEach((el) => { el.hidden = !isAutonom; });
            cloudSpacesGroups.forEach((el) => { el.hidden = isAutonom; });
        }
    };

    autonom.subscribe = function (cb: (provider: string) => void): () => void {
        subscribers.add(cb);
        return () => subscribers.delete(cb);
    };

    autonom.wrapNewSession = function (jsxRuntime?: any) {
        return function (type: any, props: any, key?: any) {
            const r = jsxRuntime || target._ || target.tX;
            const original = r.jsx(type, props, key);
            const isAutonom = autonom.isAutonomActive();

            // Render native-styled 2-segment pill switch [ Autonom | Devin Cloud ]
            // directly preceding "+ New session" in the sidebar rail menu
            const toggleItem = r.jsx(type || "li", {
                "data-slot": "sidebar-menu-item",
                className: "group/menu-item relative isolate mb-2 mt-1",
                key: "__autonom_provider_toggle_item",
                children: r.jsxs("div", {
                    className: "switch-container group/switch relative flex w-full p-0.5 rounded-[7px] bg-tint-secondary items-center h-[28px] box-border mb-1",
                    style: {
                        backgroundColor: "rgb(var(--tint-secondary, 255 255 255 / 0.06))",
                        border: "1px solid rgb(var(--border-secondary, 255 255 255 / 0.08))",
                    },
                    children: [
                        r.jsx("button", {
                            type: "button",
                            "data-provider": "autonom",
                            "data-active": String(isAutonom),
                            className: `switch-segment ${isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all`,
                            onClick: () => autonom.setProvider("autonom"),
                            children: "Autonom",
                        }),
                        r.jsx("button", {
                            type: "button",
                            "data-provider": "devin-cloud",
                            "data-active": String(!isAutonom),
                            className: `switch-segment ${!isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all`,
                            onClick: () => autonom.setProvider("devin-cloud"),
                            children: "Devin Cloud",
                        }),
                    ],
                }),
            });

            return r.jsxs(r.Fragment || "div", {
                key: "__autonom_session_rail_group",
                children: [
                    toggleItem,
                    original,
                ],
            });
        };
    };

    autonom.renderSidebar = function (jsxRuntime?: any) {
        const r = jsxRuntime || target._ || target.tX;
        if (!r) return null;

        // Render 3-Tier sidebar in React JSX
        return r.jsxs("div", {
            className: "command-center-sidebar-root flex flex-col w-full",
            key: "__autonom_sidebar_tiers",
            children: [
                // Tier 1: Rooms
                r.jsxs("div", {
                    "data-slot": "sidebar-group",
                    "data-autonom-tier": "rooms",
                    className: "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1",
                    children: [
                        r.jsxs("div", {
                            "data-slot": "sidebar-label-row",
                            className: "flex h-7 shrink-0 items-center justify-between pl-2 pr-1",
                            children: [
                                r.jsx("div", {
                                    "data-slot": "sidebar-group-label",
                                    className: "text-11 uppercase tracking-wider text-text-secondary font-semibold",
                                    children: "Coordination Rooms",
                                }),
                                r.jsx("button", {
                                    type: "button",
                                    className: "inline-flex size-5 items-center justify-center rounded hover:bg-tint-secondary text-text-secondary",
                                    children: "+",
                                }),
                            ],
                        }),
                        r.jsxs("ul", {
                            "data-slot": "sidebar-menu",
                            className: "flex w-full flex-col py-0.5",
                            children: [
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            r.jsx("span", { className: "text-text-secondary font-mono", children: "#" }),
                                            r.jsx("span", { className: "flex-1 truncate font-medium", children: "general" }),
                                            r.jsx("span", { className: "unread-badge inline-flex items-center justify-center min-w-[18px] h-4 px-1.5 rounded-full text-11 font-semibold bg-tint-secondary", children: "3" }),
                                        ],
                                    }),
                                }),
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            r.jsx("span", { className: "text-text-secondary font-mono", children: "#" }),
                                            r.jsx("span", { className: "flex-1 truncate font-medium", children: "security-review" }),
                                        ],
                                    }),
                                }),
                            ],
                        }),
                    ],
                }),
                // Tier 2: Profiles
                r.jsxs("div", {
                    "data-slot": "sidebar-group",
                    "data-autonom-tier": "profiles",
                    className: "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1",
                    children: [
                        r.jsx("div", {
                            "data-slot": "sidebar-label-row",
                            className: "flex h-7 shrink-0 items-center pl-2 pr-1",
                            children: r.jsx("div", {
                                "data-slot": "sidebar-group-label",
                                className: "text-11 uppercase tracking-wider text-text-secondary font-semibold",
                                children: "Agent Profiles",
                            }),
                        }),
                        r.jsxs("ul", {
                            "data-slot": "sidebar-menu",
                            className: "flex w-full flex-col py-0.5",
                            children: [
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            createIdenticonJsx("architect", r, 18),
                                            r.jsx("span", { className: "flex-1 truncate font-medium", children: "architect" }),
                                            r.jsx("span", {
                                                className: "status-dot inline-block size-2 rounded-full shrink-0",
                                                style: { backgroundColor: "var(--vscode-charts-green, #82c5a5)", boxShadow: "0 0 6px rgba(130,197,165,0.4)" },
                                            }),
                                        ],
                                    }),
                                }),
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            createIdenticonJsx("sentry", r, 18),
                                            r.jsx("span", { className: "flex-1 truncate font-medium", children: "sentry" }),
                                            r.jsx("span", {
                                                className: "status-dot inline-block size-2 rounded-full shrink-0",
                                                style: { backgroundColor: "var(--vscode-charts-yellow, #d9b981)" },
                                            }),
                                        ],
                                    }),
                                }),
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            createIdenticonJsx("reviewer", r, 18),
                                            r.jsx("span", { className: "flex-1 truncate font-medium", children: "reviewer" }),
                                            r.jsx("span", {
                                                className: "status-dot inline-block size-2 rounded-full shrink-0",
                                                style: { backgroundColor: "var(--vscode-disabledForeground, rgba(255,255,255,0.3))" },
                                            }),
                                        ],
                                    }),
                                }),
                            ],
                        }),
                    ],
                }),
                // Tier 3: Unassigned
                r.jsxs("div", {
                    "data-slot": "sidebar-group",
                    "data-autonom-tier": "unassigned",
                    className: "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1",
                    children: [
                        r.jsx("div", {
                            "data-slot": "sidebar-label-row",
                            className: "flex h-7 shrink-0 items-center pl-2 pr-1",
                            children: r.jsx("div", {
                                "data-slot": "sidebar-group-label",
                                className: "text-11 uppercase tracking-wider text-text-secondary font-semibold",
                                children: "Unassigned Sessions",
                            }),
                        }),
                        r.jsxs("ul", {
                            "data-slot": "sidebar-menu",
                            className: "flex w-full flex-col py-0.5",
                            children: [
                                r.jsx("li", {
                                    "data-slot": "sidebar-menu-item",
                                    className: "relative mb-0.5",
                                    children: r.jsxs("div", {
                                        "data-slot": "sidebar-menu-button",
                                        className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer",
                                        children: [
                                            r.jsx("span", { className: "text-text-secondary text-12", children: "💬" }),
                                            r.jsx("span", { className: "flex-1 truncate", children: "Fix compiler flags" }),
                                            r.jsx("span", {
                                                className: "status-dot inline-block size-2 rounded-full shrink-0",
                                                style: { backgroundColor: "var(--vscode-charts-green, #82c5a5)" },
                                            }),
                                        ],
                                    }),
                                }),
                            ],
                        }),
                    ],
                }),
                // Tier 4: Settings
                r.jsx("div", {
                    "data-slot": "sidebar-group",
                    "data-autonom-tier": "settings",
                    className: "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pt-2 mt-auto border-t border-border-secondary",
                    style: { marginTop: "auto", borderTop: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.08))" },
                    children: r.jsx("ul", {
                        "data-slot": "sidebar-menu",
                        className: "flex w-full flex-col py-0.5",
                        children: r.jsx("li", {
                            "data-slot": "sidebar-menu-item",
                            className: "relative mb-0.5",
                            children: r.jsxs("div", {
                                id: "autonom-settings-btn",
                                "data-slot": "sidebar-menu-button",
                                className: "flex w-full items-center gap-2 pl-2 pr-2 rounded-md h-[30px] hover:bg-tint-secondary text-13 cursor-pointer text-text-secondary hover:text-text-primary",
                                onClick: () => autonom.openSettings(),
                                children: [
                                    r.jsx("span", { className: "text-14", children: "⚙" }),
                                    r.jsx("span", { className: "flex-1 font-medium", children: "Autonom Settings" }),
                                ],
                            }),
                        }),
                    }),
                }),
            ],
        });
    };

    let settingsOpen = false;
    autonom.isSettingsOpen = function (): boolean {
        return settingsOpen;
    };
    autonom.openSettings = function (): void {
        settingsOpen = true;
        if (typeof window !== "undefined") {
            window.dispatchEvent(new CustomEvent("autonom:settings-opened"));
            window.dispatchEvent(new CustomEvent("autonom:provider-changed", { detail: { provider: autonom.provider } }));
        }
    };
    autonom.closeSettings = function (): void {
        settingsOpen = false;
        if (typeof window !== "undefined") {
            window.dispatchEvent(new CustomEvent("autonom:settings-closed"));
            window.dispatchEvent(new CustomEvent("autonom:provider-changed", { detail: { provider: autonom.provider } }));
        }
    };

    autonom.renderCenter = function (jsxRuntime?: any) {
        if (!settingsOpen) return null;
        const r = jsxRuntime || (typeof globalThis !== "undefined" ? (globalThis as any).__autonom_jsx : undefined) || target._ || target.tX;
        if (!r) return null;
        return createSettingsJsx(r, () => autonom.closeSettings());
    };

    autonom.mountSidebar = function (container: HTMLElement) {
        return controller.mountSidebar(container);
    };

    target.__autonom = autonom;
    return autonom;
}

export function createSettingsJsx(r: any, onClose: () => void): any {
    return r.jsxs("div", {
        className: "settings-dashboard-container flex flex-col h-full w-full overflow-y-auto p-6 bg-editor-background text-editor-foreground",
        key: "__autonom_settings_dashboard",
        style: {
            backgroundColor: "var(--vscode-editor-background, #1e1e1e)",
            color: "var(--vscode-editor-foreground, #cccccc)",
            padding: "24px 32px",
            height: "100%",
            overflowY: "auto",
        },
        children: [
            r.jsxs("div", {
                className: "settings-header flex items-center justify-between pb-4 mb-6 border-b border-border-secondary",
                style: { borderBottom: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.1))" },
                children: [
                    r.jsxs("div", {
                        className: "flex flex-col gap-1",
                        children: [
                            r.jsxs("div", {
                                className: "flex items-center gap-2",
                                children: [
                                    r.jsx("span", { className: "text-18 font-bold", children: "Autonom Command Center Settings" }),
                                    r.jsx("span", {
                                        className: "px-2 py-0.5 rounded text-11 font-medium bg-tint-secondary text-text-primary",
                                        children: "v0.4.0",
                                    }),
                                ],
                            }),
                            r.jsx("span", {
                                className: "text-12 text-text-secondary",
                                children: "Configure daemon parameters, model routing, offline timeouts, and safety policy",
                            }),
                        ],
                    }),
                    r.jsxs("button", {
                        type: "button",
                        className: "px-3 py-1.5 rounded-md text-12 font-medium bg-tint-secondary hover:bg-tint-secondary-hover text-text-primary cursor-pointer flex items-center gap-1.5",
                        onClick: onClose,
                        children: [
                            r.jsx("span", { children: "←" }),
                            r.jsx("span", { children: "Back to Sessions" }),
                        ],
                    }),
                ],
            }),
            r.jsxs("div", {
                className: "grid grid-cols-2 gap-4 max-w-4xl",
                style: { display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: "16px", maxWidth: "960px" },
                children: [
                    r.jsxs("div", {
                        className: "card p-4 rounded-lg border border-border-secondary bg-tint-tertiary flex flex-col gap-3",
                        style: {
                            padding: "16px",
                            borderRadius: "8px",
                            border: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.1))",
                            backgroundColor: "rgba(255, 255, 255, 0.03)",
                        },
                        children: [
                            r.jsxs("div", {
                                className: "flex items-center justify-between",
                                children: [
                                    r.jsx("span", { className: "font-semibold text-13", children: "Daemon Connection" }),
                                    r.jsx("span", {
                                        className: "text-11 px-2 py-0.5 rounded-full font-medium",
                                        style: { backgroundColor: "rgba(130,197,165,0.2)", color: "var(--vscode-charts-green, #82c5a5)" },
                                        children: "● Connected",
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Port" }),
                                    r.jsx("input", {
                                        type: "number",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: 8080,
                                        min: 1,
                                        max: 65535,
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Poll Interval (ms)" }),
                                    r.jsx("input", {
                                        type: "number",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: 2000,
                                        min: 500,
                                        max: 10000,
                                    }),
                                ],
                            }),
                        ],
                    }),
                    r.jsxs("div", {
                        className: "card p-4 rounded-lg border border-border-secondary bg-tint-tertiary flex flex-col gap-3",
                        style: {
                            padding: "16px",
                            borderRadius: "8px",
                            border: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.1))",
                            backgroundColor: "rgba(255, 255, 255, 0.03)",
                        },
                        children: [
                            r.jsxs("div", {
                                className: "flex items-center justify-between",
                                children: [
                                    r.jsx("span", { className: "font-semibold text-13", children: "Model & Routing" }),
                                    r.jsx("span", {
                                        className: "text-11 px-2 py-0.5 rounded font-medium",
                                        style: { backgroundColor: "rgba(78, 201, 176, 0.15)", color: "#4ec9b0" },
                                        children: "Free Tier",
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Default Model" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: "swe-2-medium",
                                        readOnly: true,
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Router Type" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: "openrouter",
                                        readOnly: true,
                                    }),
                                ],
                            }),
                        ],
                    }),
                    r.jsxs("div", {
                        className: "card p-4 rounded-lg border border-border-secondary bg-tint-tertiary flex flex-col gap-3",
                        style: {
                            padding: "16px",
                            borderRadius: "8px",
                            border: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.1))",
                            backgroundColor: "rgba(255, 255, 255, 0.03)",
                        },
                        children: [
                            r.jsx("span", { className: "font-semibold text-13", children: "Execution & Compaction" }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Offline Start After" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: "1h",
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Offline Compact After" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: "30m",
                                    }),
                                ],
                            }),
                        ],
                    }),
                    r.jsxs("div", {
                        className: "card p-4 rounded-lg border border-border-secondary bg-tint-tertiary flex flex-col gap-3",
                        style: {
                            padding: "16px",
                            borderRadius: "8px",
                            border: "1px solid var(--vscode-widget-border, rgba(255,255,255,0.1))",
                            backgroundColor: "rgba(255, 255, 255, 0.03)",
                        },
                        children: [
                            r.jsx("span", { className: "font-semibold text-13", children: "Workspace Safety Policy" }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Policy File" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: ".devin/policy.yml",
                                        readOnly: true,
                                    }),
                                ],
                            }),
                            r.jsxs("div", {
                                className: "flex flex-col gap-1",
                                children: [
                                    r.jsx("label", { className: "text-11 text-text-secondary", children: "Screening Model" }),
                                    r.jsx("input", {
                                        type: "text",
                                        className: "px-2 py-1 rounded bg-input-background border border-border-secondary text-12",
                                        defaultValue: "inception/mercury-decide:free",
                                        readOnly: true,
                                    }),
                                ],
                            }),
                        ],
                    }),
                ],
            }),
            r.jsxs("div", {
                className: "mt-6 flex items-center gap-3",
                children: [
                    r.jsx("button", {
                        type: "button",
                        className: "px-4 py-2 rounded-md text-12 font-medium bg-button-background text-button-foreground hover:bg-button-hoverBackground cursor-pointer",
                        style: {
                            backgroundColor: "var(--vscode-button-background, #007acc)",
                            color: "var(--vscode-button-foreground, #ffffff)",
                        },
                        onClick: () => {
                            if (typeof window !== "undefined") {
                                window.dispatchEvent(new CustomEvent("autonom:save-settings"));
                            }
                            onClose();
                        },
                        children: "Save Configuration",
                    }),
                    r.jsx("button", {
                        type: "button",
                        className: "px-4 py-2 rounded-md text-12 font-medium bg-secondary-button-background text-secondary-button-foreground cursor-pointer",
                        style: {
                            backgroundColor: "var(--vscode-button-secondaryBackground, rgba(255,255,255,0.1))",
                            color: "var(--vscode-button-secondaryForeground, #ffffff)",
                        },
                        onClick: onClose,
                        children: "Cancel",
                    }),
                ],
            }),
        ],
    });
}

if (typeof globalThis !== "undefined") {
    init(globalThis);
}
