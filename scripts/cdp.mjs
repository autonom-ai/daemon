// Reusable Chrome DevTools Protocol client for live Devin Desktop testing.
// No dependencies: uses Node's global WebSocket (Node >= 22) and fetch.
//
//   import { CdpSession, listTargets } from "./cdp.mjs";
//   const session = await CdpSession.open({ urlIncludes: "workbench.html" });
//   await session.clickSelector("[data-provider='autonom']");
//   console.log(await session.evaluate("1 + 1"));

const DEFAULT_PORT = 9222;

export async function listTargets(port = DEFAULT_PORT) {
    const ret = await fetch(`http://127.0.0.1:${port}/json/list`).then((res) => res.json());
    return ret;
}

export function selectTarget(targets, match = {}) {
    const { type = "page", urlIncludes, titleIncludes } = match;
    const candidates = targets.filter((target) => target.webSocketDebuggerUrl);
    const byType = type === null ? candidates : candidates.filter((target) => target.type === type);
    const byUrl = urlIncludes ? byType.filter((target) => target.url.includes(urlIncludes)) : byType;
    const byTitle = titleIncludes ? byUrl.filter((target) => target.title.includes(titleIncludes)) : byUrl;
    if (byTitle.length === 0) {
        const summary = targets.map((target) => `${target.type}: ${target.title || "(untitled)"} ${target.url}`).join("\n");
        throw new Error(`No CDP target matched ${JSON.stringify(match)}. Targets:\n${summary}`);
    }
    return byTitle[0];
}

export class CdpSession {
    constructor(socket, target) {
        this.socket = socket;
        this.target = target;
        this.nextId = 1;
        this.pending = new Map();
        this.listeners = new Map();
        this.consoleEntries = [];
        this.exceptions = [];
        socket.addEventListener("message", (event) => this.handleMessage(event.data));
        socket.addEventListener("close", () => this.handleClose());
    }

    static async open(match = { urlIncludes: "workbench.html" }, { port = DEFAULT_PORT } = {}) {
        const targets = await listTargets(port);
        const target = selectTarget(targets, match);
        const socket = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => {
            socket.addEventListener("open", resolve, { once: true });
            socket.addEventListener("error", () => reject(new Error(`WebSocket failed for ${target.url}`)), { once: true });
        });
        const session = new CdpSession(socket, target);
        await session.send("Runtime.enable");
        await session.send("Log.enable");
        return session;
    }

    handleMessage(data) {
        const message = JSON.parse(data);
        if (message.id !== undefined) {
            const entry = this.pending.get(message.id);
            if (!entry) return;
            this.pending.delete(message.id);
            if (message.error) entry.reject(new Error(`${entry.method}: ${message.error.message}`));
            else entry.resolve(message.result);
            return;
        }
        if (message.method === "Runtime.exceptionThrown") {
            const details = message.params.exceptionDetails;
            const text = details.exception?.description || details.text;
            this.exceptions.push({ text, url: details.url, line: details.lineNumber });
        }
        if (message.method === "Log.entryAdded" && message.params.entry.level === "error") {
            this.consoleEntries.push({ text: message.params.entry.text, url: message.params.entry.url });
        }
        if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
            const text = message.params.args.map((arg) => arg.description || arg.value || "").join(" ");
            this.consoleEntries.push({ text, url: message.params.stackTrace?.callFrames?.[0]?.url });
        }
        const handlers = this.listeners.get(message.method);
        if (handlers) for (const handler of handlers) handler(message.params);
    }

    handleClose() {
        for (const entry of this.pending.values()) entry.reject(new Error("CDP socket closed"));
        this.pending.clear();
    }

    on(method, handler) {
        if (!this.listeners.has(method)) this.listeners.set(method, new Set());
        this.listeners.get(method).add(handler);
        return () => this.listeners.get(method)?.delete(handler);
    }

    send(method, params = {}) {
        const id = this.nextId++;
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject, method });
            this.socket.send(JSON.stringify({ id, method, params }));
        });
    }

    async evaluate(expression, { awaitPromise = true, returnByValue = true } = {}) {
        const result = await this.send("Runtime.evaluate", {
            expression,
            awaitPromise,
            returnByValue,
            userGesture: true,
        });
        if (result.exceptionDetails) {
            const details = result.exceptionDetails;
            throw new Error(`evaluate failed: ${details.exception?.description || details.text}`);
        }
        return result.result?.value;
    }

    async evaluateFunction(fn, ...args) {
        const serialized = args.map((arg) => JSON.stringify(arg)).join(", ");
        return this.evaluate(`(${fn.toString()})(${serialized})`);
    }

    async elementRect(selector) {
        return this.evaluateFunction((sel) => {
            const element = document.querySelector(sel);
            if (!element) return null;
            const rect = element.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return { empty: true, rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
            return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
        }, selector);
    }

    async clickPoint(x, y, { button = "left", clickCount = 1 } = {}) {
        const base = { x, y, button, clickCount, pointerType: "mouse" };
        await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...base, button: "none" });
        await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
        await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
    }

    // Physical mouse click at the element's rendered center. Fails when the element
    // is missing or has zero layout size, so tests cannot silently no-op.
    async clickSelector(selector) {
        const rect = await this.elementRect(selector);
        if (!rect) throw new Error(`clickSelector: no element for ${selector}`);
        if (rect.empty) throw new Error(`clickSelector: element ${selector} has no layout box`);
        await this.clickPoint(rect.x, rect.y);
        return rect.rect;
    }

    async clickText(text, { selector = "button, [role='button'], a, li, div" } = {}) {
        const rect = await this.evaluateFunction((label, scope) => {
            const matches = [...document.querySelectorAll(scope)].filter(
                (element) => element.textContent.trim() === label && element.getClientRects().length > 0,
            );
            if (matches.length === 0) return null;
            const smallest = matches.reduce((best, element) => {
                const size = element.getBoundingClientRect();
                const bestSize = best.getBoundingClientRect();
                return size.width * size.height < bestSize.width * bestSize.height ? element : best;
            });
            const rect = smallest.getBoundingClientRect();
            return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, count: matches.length };
        }, text, selector);
        if (!rect) throw new Error(`clickText: no visible element with text "${text}"`);
        await this.clickPoint(rect.x, rect.y);
        return rect;
    }

    async waitFor(expression, { timeout = 5000, interval = 150, description } = {}) {
        const deadline = Date.now() + timeout;
        let lastError = null;
        while (Date.now() < deadline) {
            try {
                const value = await this.evaluate(expression);
                if (value) return value;
            } catch (error) {
                lastError = error;
            }
            await new Promise((resolve) => setTimeout(resolve, interval));
        }
        const label = description || expression;
        throw new Error(`waitFor timed out after ${timeout}ms: ${label}${lastError ? ` (last error: ${lastError.message})` : ""}`);
    }

    async reload({ waitForLoad = true } = {}) {
        const loaded = new Promise((resolve) => {
            const off = this.on("Page.loadEventFired", () => {
                off();
                resolve();
            });
        });
        await this.send("Page.enable");
        await this.send("Page.reload", { ignoreCache: true });
        if (waitForLoad) await Promise.race([loaded, new Promise((resolve) => setTimeout(resolve, 15000))]);
    }

    // Capture a PNG screenshot of the visible page; returns the raw base64 payload.
    async screenshot({ clip } = {}) {
        const result = await this.send("Page.captureScreenshot", {
            format: "png",
            ...(clip ? { clip: { ...clip, scale: 1 } } : {}),
        });
        return result.data;
    }

    // Structured snapshot of the injected Autonom Command Center state.
    async commandCenterState() {
        return this.evaluateFunction(() => {
            const describe = (element) => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return {
                    tag: element.tagName.toLowerCase(),
                    display: style.display,
                    visibility: style.visibility,
                    hidden: element.hidden,
                    checkVisibility: element.checkVisibility(),
                    rendered: rect.width > 0 && rect.height > 0,
                    rect: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
                    text: element.textContent.trim().slice(0, 60),
                };
            };
            const api = globalThis.__autonom || {};
            const apiSurface = {};
            for (const key of Object.getOwnPropertyNames(api)) {
                try {
                    apiSurface[key] = typeof api[key];
                } catch {
                    apiSurface[key] = "error";
                }
            }
            const select = (selector) => [...document.querySelectorAll(selector)].map(describe);
            return {
                provider: {
                    runtime: api.provider,
                    stored: localStorage.getItem("autonom.provider"),
                },
                apiSurface,
                settingsOpen: typeof api.isSettingsOpen === "function" ? api.isSettingsOpen() : null,
                roots: select(".command-center-sidebar-root"),
                providerButtons: select("[data-provider]"),
                settingsButtons: select("[data-autonom-settings], [data-action='open-settings'], .autonom-settings-button"),
                settingsLayers: select(".command-center-settings, [data-autonom-settings-layer]"),
                autonTiers: select("[data-autonom-tier]"),
                cloudGroups: select("[data-slot='sidebar-group']:not([data-autonom-tier])"),
                roomRows: select("[data-room-name], [data-autonom-room]"),
                profileRows: select("[data-profile-name], [data-autonom-profile]"),
                sessionRows: select("[data-session-name], [data-autonom-session]"),
                newSession: select("[aria-label='New session']"),
            };
        });
    }

    close() {
        try {
            this.socket.close();
        } catch {
            // socket already closed
        }
    }
}

export async function withSession(match, fn, options) {
    const session = await CdpSession.open(match, options);
    try {
        return await fn(session);
    } finally {
        session.close();
    }
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
