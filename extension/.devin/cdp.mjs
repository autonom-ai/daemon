import { readFile, writeFile } from "node:fs/promises";

const [action = "targets", target = "workbench", rawInput = ""] = process.argv.slice(2);
const input = rawInput.startsWith("@") ? await readFile(rawInput.slice(1), "utf8") : rawInput;
const port = process.env.CDP_PORT || "9882";
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
if (action === "targets") {
    console.log(JSON.stringify(targets, null, 2));
    process.exit(0);
}
const page = targets.find((entry) => (entry.type === "page" || entry.type === "iframe")
    && (entry.id === target || entry.url.includes(target)));
if (!page)
    throw new Error(`No target matching ${target}`);
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
});
let sequence = 0;
const pending = new Map();
const scripts = [];
socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.method === "Debugger.scriptParsed")
        scripts.push(message.params);
    const request = pending.get(message.id);
    if (!request)
        return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error)
        request.reject(new Error(JSON.stringify(message.error)));
    else
        request.resolve(message.result);
});
function send(method, params = {}) {
    return new Promise((resolve, reject) => {
        const id = ++sequence;
        const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`Timed out: ${method}`));
        }, 30000);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params }));
    });
}
try {
    if (action === "eval") {
        const result = await send("Runtime.evaluate", { expression: input, returnByValue: true, awaitPromise: true });
        if (result.exceptionDetails)
            throw new Error(JSON.stringify(result.exceptionDetails));
        console.log(JSON.stringify(result.result.value ?? result.result, null, 2));
    } else if (action === "screenshot") {
        const result = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
        await writeFile(input, Buffer.from(result.data, "base64"));
        console.log(input);
    } else if (action === "key") {
        const params = JSON.parse(input);
        await send("Input.dispatchKeyEvent", { type: "keyDown", ...params });
        await send("Input.dispatchKeyEvent", { type: "keyUp", ...params });
    } else if (action === "text") {
        await send("Input.insertText", { text: input });
    } else if (action === "reload") {
        await send("Page.reload", { ignoreCache: true });
    } else if (action === "command") {
        const code = await readFile(new URL("../dist/commandCenter/native.js", import.meta.url), "utf8");
        const request = JSON.parse(input);
        const args = Array.isArray(request.arguments) ? request.arguments : [];
        const expression = `(async()=>{${code};globalThis.__autonomLiveProbe=AutonomNative.probe();`
            + `if(!globalThis.__autonomLiveProbe)throw new Error("Native sidebar is not ready");`
            + `return await globalThis.__autonomLiveProbe.api.executeCommand(${JSON.stringify(request.command)},...${JSON.stringify(args)})})()`;
        const result = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
        if (result.exceptionDetails)
            throw new Error(JSON.stringify(result.exceptionDetails));
        console.log(JSON.stringify(result.result.value ?? result.result, null, 2));
    } else if (action === "install") {
        const code = await readFile(new URL("../dist/commandCenter/native.js", import.meta.url), "utf8");
        const result = await send("Runtime.evaluate", {
            expression: `${code};globalThis.__autonomServices.windowId=window.vscodeWindowId;globalThis.__autonomServices.api=globalThis.__autonomProbe.vscodeAPI;AutonomNative.install(globalThis.__autonomServices,"live-proof").update(${input})`,
            returnByValue: true,
            awaitPromise: true,
        });
        if (result.exceptionDetails)
            throw new Error(JSON.stringify(result.exceptionDetails));
        console.log(JSON.stringify(result.result.value, null, 2));
    } else if (action === "capture" || action === "hot") {
        const nativeCode = await readFile(new URL("../dist/commandCenter/native.js", import.meta.url), "utf8");
        await send("Debugger.enable");
        await send("Runtime.evaluate", {
            expression: `${nativeCode};globalThis.AutonomNative=AutonomNative;globalThis.__autonomProbe=AutonomNative.probe();Boolean(globalThis.__autonomProbe)`,
            returnByValue: true,
        });
        const capture = async (expression, assignments) => {
            const reference = await send("Runtime.evaluate", { expression });
            const breakpoint = await send("Debugger.setBreakpointOnFunctionCall", { objectId: reference.result.objectId });
            let resolvePaused;
            const paused = new Promise((resolve) => { resolvePaused = resolve; });
            const listener = async (event) => {
                const message = JSON.parse(event.data);
                if (message.method !== "Debugger.paused")
                    return;
                try {
                    const result = await send("Debugger.evaluateOnCallFrame", {
                        callFrameId: message.params.callFrames[0].callFrameId,
                        expression: assignments,
                        returnByValue: true,
                    });
                    console.log(JSON.stringify(result));
                } finally {
                    await send("Debugger.removeBreakpoint", { breakpointId: breakpoint.breakpointId });
                    await send("Debugger.resume");
                    socket.removeEventListener("message", listener);
                    resolvePaused();
                }
            };
            socket.addEventListener("message", listener);
            await send("Runtime.evaluate", { expression: `(${expression})()`, returnByValue: true });
            await paused;
        };
        await capture("globalThis.__autonomProbe.props.getDesktopNavSurfacesSnapshot", "globalThis.__autonomServices={manifest:this._manifestService,controller:yAe.prototype}; ({manifest:!!globalThis.__autonomServices.manifest,controller:!!globalThis.__autonomServices.controller})");
        await capture("globalThis.__autonomProbe.props.getActiveDesktopNavSurfaceSnapshot", "globalThis.__autonomServices.groups=o; ({groups:typeof o.getActiveNavSurface,windowId:e.vscodeWindowId})");
        await send("Debugger.disable");
        if (action === "hot") {
            const result = await send("Runtime.evaluate", {
                expression: "globalThis.__autonomCenter?.dispose();"
                    + `${nativeCode};globalThis.AutonomNative=AutonomNative;`
                    + "globalThis.__autonomServices.windowId=window.vscodeWindowId;"
                    + "globalThis.__autonomServices.api=globalThis.__autonomProbe.api;"
                    + `globalThis.AutonomNative.install(globalThis.__autonomServices,"live-proof",false)`
                    + `.update(${input},false)`,
                returnByValue: true,
                awaitPromise: true,
            });
            if (result.exceptionDetails)
                throw new Error(JSON.stringify(result.exceptionDetails));
            console.log(JSON.stringify(result.result.value, null, 2));
        }
    } else if (action === "scopes") {
        const result = await send("Runtime.evaluate", { expression: input });
        const properties = await send("Runtime.getProperties", { objectId: result.result.objectId });
        const scopes = properties.internalProperties.find((entry) => entry.name === "[[Scopes]]");
        const entries = await send("Runtime.getProperties", { objectId: scopes.value.objectId, ownProperties: true });
        for (const entry of entries.result.filter((entry) => entry.value?.objectId)) {
            const scope = await send("Runtime.getProperties", { objectId: entry.value.objectId, ownProperties: true });
            console.log(JSON.stringify({ scope: entry.value.description, names: scope.result.map((entry) => entry.name) }));
        }
    } else if (action === "analyze") {
        await send("Debugger.enable");
        for (const script of scripts.filter((entry) => /windsurf-chat-client\/index.js|sessions.desktop.main.js/.test(entry.url))) {
            const { scriptSource } = await send("Debugger.getScriptSource", { scriptId: script.scriptId });
            const patterns = input ? JSON.parse(input) : ["Automations", "WTr=", "ewt=", "jY,", "tg,", "activeTab", "setActiveTab", "__autonom"];
            console.log(script.url);
            for (const pattern of patterns) {
                let offset = 0;
                let count = 0;
                while ((offset = scriptSource.indexOf(pattern, offset)) >= 0 && count++ < 12) {
                    console.log(JSON.stringify({ pattern, offset, source: scriptSource.slice(Math.max(0, offset - 700), offset + 1300) }));
                    offset += pattern.length;
                }
            }
        }
    } else {
        throw new Error(`Unknown action: ${action}`);
    }
} finally {
    socket.close();
}
