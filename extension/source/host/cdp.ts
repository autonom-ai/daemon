/**
 * Extension-host transport to the Devin Desktop renderer.
 *
 * This module owns the trust boundary between the extension host and Desktop.
 * It discovers the exact renderer for this activation, verifies the Desktop
 * build against a pinned fingerprint, captures the native navigation service
 * references, and injects the runtime. It is read-only with respect to Desktop:
 * it never writes vendor files, checksums, CSP, or profile data. All renderer
 * communication is bounded and loopback-only. See docs/COMMAND_CENTER.md.
 */
import type { CenterContent } from "../commandCenter/content";
import { probe } from "../commandCenter/native";
import type { RuntimeStatus } from "../commandCenter/native";

import { createHash } from "node:crypto";
import { constants, createReadStream } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const REQUEST_TIMEOUT = 8000;
const MAX_MESSAGE_BYTES = 2 * 1024 * 1024;
const MAX_LIST_BYTES = 1024 * 1024;
const NATIVE_HASH = "da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d";
const NATIVE_COMMIT = "fcf7ba39e6150055fad817f8716385b4d320d46d";
const KNOWN_LEGACY_PATCH_CHECKSUMS: Record<string, string> = {
    "vs/workbench/windsurf-chat-client/index.js": "T4cy3Ll+I6Laqus1lE3ElPypPs8ENuBYJnmDClkoHRc",
    "vs/sessions/sessions.desktop.main.js": "liA1izP/FNrOaJzLUE6jDrmq8enLepJeI6yDECPqkQk",
    "vs/sessions/electron-browser/sessions.html": "35t8LVmoirBqC8xVfJyYl1SbDcNj3CPmBL545prtci4",
};
const KNOWN_PRISTINE_PATCH_FILES: Record<string, string> = {
    "vs/workbench/windsurf-chat-client/index.js": "guLMvBVF8IkoBa9R2R7CqfqChScmSTgg2U2aCP+WMOg",
    "vs/sessions/sessions.desktop.main.js": "i1ZQZrYIo9o2NMDi7JZzbPeOkmYVQGp+6FVxtC4NAzU",
    "vs/sessions/electron-browser/sessions.html": "dkYHBf/gUpCB9fcZuauEq5PmTNmKhE/RryNXY6vMLtQ",
    "vs/code/electron-browser/workbench/workbench.html": "o3yw1bDVfKxWhCUpw54oG4ePEpuumUGAzHGAZwVtDtw",
};

type ProtocolRecord = Record<string, any>;
type EventListener = (parameters: ProtocolRecord) => void;

interface PendingRequest
{
    resolve: (value: ProtocolRecord) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
}

function validatePort(port: number): void
{
    if (!Number.isInteger(port) || port < 1 || port > 65535)
        throw new Error("The renderer debugging port must be an integer between 1 and 65535.");
}

function validateSocketUrl(address: string, port: number): void
{
    validatePort(port);
    const url = new URL(address);
    if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1" || url.port !== String(port)
        || url.username || url.password || url.search || url.hash
        || !address.startsWith(`ws://127.0.0.1:${port}/devtools/page/`)
        || !/^\/devtools\/page\/[^/]+$/.test(url.pathname))
        throw new Error("The renderer debugging socket must use the configured loopback port.");
}

/**
 * Minimal, defensive CDP client over a single validated WebSocket.
 *
 * Correlates replies by id, bounds message size and pending requests, rejects
 * every pending call on close or error, and scopes event listeners. It uses
 * only the domains required for capture and evaluation; it never enables
 * logging, network, or heap domains.
 */
export class CdpClient
{
    private readonly socket: WebSocket;
    private readonly requests = new Map<number, PendingRequest>();
    private readonly listeners = new Map<string, Set<EventListener>>();
    private sequence = 0;
    private closed = false;
    private readonly ready: Promise<void>;

    private constructor(address: string, private readonly timeout: number)
    {
        this.socket = new WebSocket(address);
        this.ready = new Promise<void>((resolve, reject) =>
        {
            const timer = setTimeout(() =>
            {
                this.fail(new Error("Timed out connecting to the renderer debugging socket."));
            }, timeout);
            this.socket.addEventListener("open", () =>
            {
                clearTimeout(timer);
                if (!this.closed)
                    resolve();
            }, { once: true });
            this.socket.addEventListener("close", () =>
            {
                clearTimeout(timer);
                const error = new Error("The renderer debugging socket closed.");
                reject(error);
                this.fail(error);
            });
            this.socket.addEventListener("error", () =>
            {
                clearTimeout(timer);
                const error = new Error("The renderer debugging socket failed.");
                reject(error);
                this.fail(error);
            });
            this.socket.addEventListener("message", (event) =>
            {
                this.receive(event.data);
            });
            const rejectConnection = () =>
            {
                clearTimeout(timer);
                reject(new Error("The renderer debugging connection was cancelled."));
            };
            this.listeners.set("closed", new Set([rejectConnection]));
        });
    }

    static async connect(address: string, port: number, timeout = REQUEST_TIMEOUT): Promise<CdpClient>
    {
        validateSocketUrl(address, port);
        if (!Number.isFinite(timeout) || timeout <= 0 || timeout > REQUEST_TIMEOUT)
            throw new Error("Invalid renderer debugging timeout.");
        const ret = new CdpClient(address, timeout);
        await ret.ready;
        return ret;
    }

    get connected(): boolean
    {
        return !this.closed && this.socket.readyState === 1;
    }

    request(method: string, parameters: ProtocolRecord = {}): Promise<ProtocolRecord>
    {
        if (!this.connected)
            return Promise.reject(new Error("The renderer debugging socket is not connected."));
        if (this.requests.size >= 128)
            return Promise.reject(new Error("Too many pending renderer debugging requests."));
        const id = ++this.sequence;
        return new Promise((resolve, reject) =>
        {
            const timer = setTimeout(() =>
            {
                this.requests.delete(id);
                reject(new Error(`Timed out waiting for ${method}.`));
            }, this.timeout);
            this.requests.set(id, { resolve, reject, timer });
            try
            {
                const message = JSON.stringify({ id, method, params: parameters });
                if (Buffer.byteLength(message) > MAX_MESSAGE_BYTES)
                    throw new Error("The renderer debugging request is too large.");
                this.socket.send(message);
            }
            catch
            {
                this.requests.delete(id);
                clearTimeout(timer);
                reject(new Error("Unable to send the renderer debugging request."));
            }
        });
    }

    on(method: string, listener: EventListener): () => void
    {
        let listeners = this.listeners.get(method);
        if (!listeners)
        {
            listeners = new Set();
            this.listeners.set(method, listeners);
        }
        listeners.add(listener);
        return () =>
        {
            listeners.delete(listener);
            if (!listeners.size)
                this.listeners.delete(method);
        };
    }

    close(): void
    {
        this.fail(new Error("The renderer debugging connection was closed."));
    }

    private fail(error: Error): void
    {
        if (this.closed)
            return;
        this.closed = true;
        for (const request of this.requests.values())
        {
            clearTimeout(request.timer);
            request.reject(error);
        }
        this.requests.clear();
        for (const listener of this.listeners.get("closed") ?? [])
            listener({});
        this.listeners.clear();
        if (this.socket.readyState < 2)
            this.socket.close();
    }

    private receive(data: unknown): void
    {
        if (this.closed)
            return;
        try
        {
            if (typeof data !== "string" || Buffer.byteLength(data) > MAX_MESSAGE_BYTES)
                throw new Error("Invalid renderer debugging message.");
            const message: unknown = JSON.parse(data);
            if (!message || typeof message !== "object" || Array.isArray(message))
                throw new Error("Invalid renderer debugging message.");
            const record = message as ProtocolRecord;
            if (Object.hasOwn(record, "id"))
            {
                if (!Number.isSafeInteger(record.id) || record.id <= 0
                    || (!Object.hasOwn(record, "result") && !Object.hasOwn(record, "error")))
                    throw new Error("Invalid renderer debugging response.");
                if (record.error !== undefined && (!record.error || typeof record.error !== "object")
                    || record.result !== undefined && (!record.result || typeof record.result !== "object"
                        || Array.isArray(record.result)))
                    throw new Error("Invalid renderer debugging response.");
                const request = this.requests.get(record.id);
                if (!request)
                    return;
                this.requests.delete(record.id);
                clearTimeout(request.timer);
                if (record.error)
                    request.reject(new Error("The renderer rejected a debugging request."));
                else
                    request.resolve(record.result);
            }
            else
            {
                if (typeof record.method !== "string" || !record.params || typeof record.params !== "object"
                    || Array.isArray(record.params))
                    throw new Error("Invalid renderer debugging event.");
                for (const listener of this.listeners.get(record.method) ?? [])
                    listener(record.params);
            }
        }
        catch
        {
            this.fail(new Error("Invalid renderer debugging message."));
        }
    }
}

/** Reads a bounded regular JSON file without following symlinks. */
async function readMetadata(path: string): Promise<ProtocolRecord>
{
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const buffer = Buffer.alloc(MAX_LIST_BYTES + 1);
        const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
        if (bytesRead > MAX_LIST_BYTES)
            throw new Error("The Desktop build metadata is too large.");
        const ret: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
        if (!ret || typeof ret !== "object" || Array.isArray(ret))
            throw new Error("Invalid Desktop build metadata.");
        return ret as ProtocolRecord;
    }
    finally
    {
        await file.close();
    }
}

/**
 * Computes the unpadded Base64 SHA-256 of one Desktop `out/` file, matching
 * the format Devin's own integrity service uses. Rejects unsafe paths and
 * non-regular or oversized files.
 */
async function checksumFile(appRoot: string, relativePath: string): Promise<string>
{
    if (!/^vs\/[a-zA-Z0-9._/-]+$/.test(relativePath)
        || relativePath.split("/").some((segment) => segment === "" || segment === "." || segment === ".."))
        throw new Error("Unsafe Desktop checksum path.");
    const file = await open(join(appRoot, "out", relativePath), constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await file.stat();
        if (!attributes.isFile() || attributes.size > 64 * 1024 * 1024)
            throw new Error("Desktop checksum target is not a bounded regular file.");
        const hash = createHash("sha256");
        for await (const chunk of file.createReadStream({ autoClose: false }))
            hash.update(chunk);
        return hash.digest("base64").replace(/=+$/g, "");
    }
    finally
    {
        await file.close();
    }
}

/**
 * Proves whether the only integrity mismatch is the known legacy Autonom 0.4.0
 * residue, so the runtime may dismiss that one toast.
 *
 * Fails closed: returns false unless the build is the pinned version/commit,
 * every product checksum mismatch is exactly one of the known old patched
 * hashes, every restored file matches its recorded pristine hash, and the saved
 * pristine checksum snapshot matches the expected values. Any extra, missing,
 * or unknown mismatch returns false and leaves the native warning visible.
 */
export async function verifyPatchOnlyWarningCase(appRoot: string): Promise<boolean>
{
    try
    {
        const product = await readMetadata(join(appRoot, "product.json"));
        const metadata = await readMetadata(join(appRoot, "package.json"));
        if (metadata.version !== "1.126.0" || product.commit !== NATIVE_COMMIT
            || !product.checksums || typeof product.checksums !== "object"
            || Array.isArray(product.checksums))
            return false;
        const checksums = product.checksums as Record<string, unknown>;
        const entries = Object.entries(checksums);
        if (entries.length === 0 || entries.length > 128)
            return false;
        const saved = await readMetadata(join(appRoot, "out/vs/sessions/product.checksums.orig.json"));
        if (Object.keys(saved).length !== Object.keys(KNOWN_PRISTINE_PATCH_FILES).length)
            return false;
        for (const [file, pristine] of Object.entries(KNOWN_PRISTINE_PATCH_FILES))
        {
            if (saved[file] !== pristine)
                return false;
        }
        const mismatched: string[] = [];
        let totalBytes = 0;
        for (const [file, expected] of entries)
        {
            if (typeof expected !== "string")
                return false;
            totalBytes += Buffer.byteLength(file) + Buffer.byteLength(expected);
            if (totalBytes > MAX_LIST_BYTES)
                return false;
            const actual = await checksumFile(appRoot, file);
            if (actual !== expected)
                mismatched.push(file);
            if (Object.hasOwn(KNOWN_PRISTINE_PATCH_FILES, file)
                && actual !== KNOWN_PRISTINE_PATCH_FILES[file])
                return false;
        }
        const expectedMismatches = Object.keys(KNOWN_LEGACY_PATCH_CHECKSUMS).sort();
        mismatched.sort();
        return mismatched.length === expectedMismatches.length
            && mismatched.every((file, index) => file === expectedMismatches[index])
            && mismatched.every((file) => checksums[file] === KNOWN_LEGACY_PATCH_CHECKSUMS[file])
            && mismatched.every((file) => saved[file] === KNOWN_PRISTINE_PATCH_FILES[file]);
    }
    catch
    {
        return false;
    }
}

/**
 * Fails closed unless the Desktop build matches the pinned version, commit,
 * and native host bundle hash. This is the gate that makes the minified
 * service-name assumptions safe.
 */
async function verifyBuild(appRoot: string): Promise<void>
{
    const product = await readMetadata(join(appRoot, "product.json"));
    const metadata = await readMetadata(join(appRoot, "package.json"));
    if (metadata.version !== "1.126.0" || product.commit !== NATIVE_COMMIT)
        throw new Error("Unsupported Desktop build. Command Center requires version 1.126.0 and its pinned commit.");
    const hash = createHash("sha256");
    let bytes = 0;
    for await (const chunk of createReadStream(join(appRoot, "out/vs/workbench/workbench.desktop.main.js")))
    {
        bytes += chunk.length;
        if (bytes > 32 * 1024 * 1024)
            throw new Error("The native Desktop host bundle is too large.");
        hash.update(chunk);
    }
    if (hash.digest("hex") !== NATIVE_HASH)
        throw new Error("The native Desktop host bundle is not the verified pristine build. "
            + "Restore it before attaching.");
}

/**
 * Returns the validated debugging sockets of candidate Desktop workbench pages.
 *
 * Only exact workbench page URLs on the configured loopback port qualify;
 * iframes, workers, and other pages are ignored. Enforces bounded target count
 * and socket shape, and refuses redirects.
 */
async function targetSockets(appRoot: string, port: number): Promise<string[]>
{
    const controller = new AbortController();
    const timeout = setTimeout(() =>
    {
        controller.abort();
    }, REQUEST_TIMEOUT);
    try
    {
        const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
            signal: controller.signal,
            redirect: "error",
        });
        if (!response.ok || !response.body)
            throw new Error("The Desktop renderer target list is unavailable.");
        const reader = response.body.getReader();
        const chunks: Uint8Array[] = [];
        let bytes = 0;
        try
        {
            while (true)
            {
                const chunk = await reader.read();
                if (chunk.done)
                    break;
                bytes += chunk.value.byteLength;
                if (bytes > MAX_LIST_BYTES)
                    throw new Error("The Desktop renderer target list is too large.");
                chunks.push(chunk.value);
            }
        }
        finally
        {
            await reader.cancel().catch(() =>
            {
            });
            reader.releaseLock();
        }
        const targets: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (!Array.isArray(targets) || targets.length > 128)
            throw new Error("Invalid Desktop renderer target list.");
        const path = pathToFileURL(join(appRoot, "out/vs/code/electron-browser/workbench/workbench.html")).pathname;
        const url = `vscode-file://vscode-app${path}`;
        const ret: string[] = [];
        for (const target of targets)
        {
            if (!target || typeof target !== "object" || target.type !== "page" || target.url !== url)
                continue;
            if (typeof target.webSocketDebuggerUrl !== "string")
                throw new Error("The Desktop renderer target has no debugging socket.");
            validateSocketUrl(target.webSocketDebuggerUrl, port);
            if (ret.includes(target.webSocketDebuggerUrl) || ret.length >= 8)
                throw new Error("Ambiguous or excessive Desktop renderer targets.");
            ret.push(target.webSocketDebuggerUrl);
        }
        return ret;
    }
    catch
    {
        throw new Error("Cannot discover Desktop renderers on the configured loopback debugging port.");
    }
    finally
    {
        clearTimeout(timeout);
    }
}

function disconnectedStatus(): RuntimeStatus
{
    return {
        connected: false,
        mode: "devin-cloud",
        enabled: false,
        patchOnlyIntegrityNoticeSuppressed: false,
        revision: null,
        activeTab: null,
        windowId: 0,
        items: [],
    };
}

function statusExpression(expression: string): string
{
    return `(async()=>{const ret=await (${expression});if(!ret)return null;return {connected:ret.connected,`
        + "mode:ret.mode,enabled:ret.enabled,patchOnlyIntegrityNoticeSuppressed:ret.patchOnlyIntegrityNoticeSuppressed,"
        + "revision:ret.revision,activeTab:ret.activeTab,windowId:ret.windowId,"
        + "items:ret.items.map(item=>({id:item.id,label:item.label,path:item.path}))};})()";
}

function validateStatus(value: unknown): RuntimeStatus
{
    const ret = value as RuntimeStatus;
    if (!ret || typeof ret.connected !== "boolean" || typeof ret.enabled !== "boolean"
        || typeof ret.patchOnlyIntegrityNoticeSuppressed !== "boolean"
        || (ret.mode !== "autonom" && ret.mode !== "devin-cloud")
        || typeof ret.patchOnlyIntegrityNoticeSuppressed !== "boolean"
        || (ret.revision !== null && typeof ret.revision !== "string")
        || (ret.activeTab !== null && typeof ret.activeTab !== "string")
        || !Number.isSafeInteger(ret.windowId) || !Array.isArray(ret.items) || ret.items.length > 512
        || ret.items.some((item) =>
        {
            return !item || typeof item.id !== "string" || typeof item.label !== "string"
                || typeof item.path !== "string";
        }))
        throw new Error("The native Command Center returned an invalid status.");
    return {
        connected: ret.connected,
        mode: ret.mode,
        enabled: ret.enabled,
        patchOnlyIntegrityNoticeSuppressed: ret.patchOnlyIntegrityNoticeSuppressed === true,
        revision: ret.revision,
        activeTab: ret.activeTab,
        windowId: ret.windowId,
        items: ret.items.map((item) =>
        {
            return { id: item.id, label: item.label, path: item.path };
        }),
    };
}

/**
 * High-level owner of the renderer runtime for one extension activation.
 *
 * Serializes every operation, verifies the build before mutating, discovers and
 * binds to exactly one renderer by activation identity, keeps the runtime alive
 * with a heartbeat, and treats any socket loss as a detach. Status reporting is
 * whitelisted to safe, bounded fields.
 */
export class RuntimeCenter
{
    private client: CdpClient | null = null;
    private pending: Promise<void> = Promise.resolve();
    private heartbeat: ReturnType<typeof setInterval> | null = null;
    private heartbeatPending = false;
    private objectSequence = 0;
    private patchOnlyIntegrityNoticeSuppressed = false;

    constructor(
        private runtimeCode: string,
        private readonly identity: string,
        private readonly appRoot: string,
        private readonly port = 9882,
    )
    {
        validatePort(port);
        if (!runtimeCode || !identity || !appRoot)
            throw new Error("A runtime build, activation identity and Desktop app root are required.");
    }

    attach(content: CenterContent): Promise<RuntimeStatus>
    {
        return this.serialize(() =>
        {
            return this.apply(content);
        });
    }

    update(content: CenterContent): Promise<RuntimeStatus>
    {
        return this.serialize(() =>
        {
            return this.apply(content);
        });
    }

    detach(): Promise<void>
    {
        return this.serialize(async () =>
        {
            this.stopHeartbeat();
            const client = this.client;
            try
            {
                if (client?.connected)
                {
                    await this.evaluate(client, `(async()=>{const runtime=globalThis.__autonomCenter;`
                        + `if(runtime?.owner===${JSON.stringify(this.identity)})await runtime.dispose();})()`);
                }
            }
            finally
            {
                this.disconnect();
            }
        });
    }

    status(): Promise<RuntimeStatus>
    {
        return this.serialize(async () =>
        {
            if (!this.client?.connected)
            {
                this.disconnect();
                return disconnectedStatus();
            }
            try
            {
                const ret = await this.evaluate(this.client, statusExpression(
                    `globalThis.__autonomCenter?.owner===${JSON.stringify(this.identity)}`
                    + "?globalThis.__autonomCenter.status():null"));
                if (ret === null)
                {
                    this.disconnect();
                    return disconnectedStatus();
                }
                return validateStatus(ret);
            }
            catch (error)
            {
                this.disconnect();
                throw error;
            }
        });
    }

    reloadRuntime(runtimeCode: string, content: CenterContent): Promise<RuntimeStatus>
    {
        return this.serialize(async () =>
        {
            if (!runtimeCode)
                throw new Error("The native Command Center runtime bundle is empty.");
            await verifyBuild(this.appRoot);
            this.patchOnlyIntegrityNoticeSuppressed = await verifyPatchOnlyWarningCase(this.appRoot);
            if (!this.client?.connected)
            {
                this.disconnect();
                this.client = await this.discover();
            }
            const client = this.client;
            let failed = true;
            try
            {
                const owner = await this.evaluate(client, "globalThis.__autonomCenter?.owner??null");
                if (owner !== this.identity)
                    throw new Error("The native Command Center runtime is not owned by this extension activation.");
                await this.evaluate(client, `globalThis.__autonomAttachProbe=(${probe.toString()})();true`);
                await this.captureServices(client);
                const ret = await this.evaluate(client, runtimeCode + ";" + statusExpression(
                    `AutonomNative.replace(globalThis.__autonomServices,${JSON.stringify(this.identity)},`
                    + `${this.patchOnlyIntegrityNoticeSuppressed}).update(${JSON.stringify(content)},`
                    + `${this.patchOnlyIntegrityNoticeSuppressed})`));
                this.runtimeCode = runtimeCode;
                failed = false;
                this.startHeartbeat();
                return validateStatus(ret);
            }
            finally
            {
                try
                {
                    if (client.connected)
                        await this.clearTemporary(client);
                }
                catch
                {
                    failed = true;
                    throw new Error("Unable to release temporary renderer references after hot reload.");
                }
                finally
                {
                    if (failed)
                        this.disconnect();
                }
            }
        });
    }

    open(tabId: string): Promise<RuntimeStatus>
    {
        return this.serialize(async () =>
        {
            if (!this.client?.connected)
                throw new Error("Attach the native Command Center before opening a tab.");
            const ret = await this.evaluate(this.client, statusExpression(
                `globalThis.__autonomCenter?.owner===${JSON.stringify(this.identity)}`
                + `?globalThis.__autonomCenter.open(${JSON.stringify(tabId)}):null`));
            if (ret === null)
            {
                this.disconnect();
                throw new Error("The native Command Center runtime is gone. Attach again before opening a tab.");
            }
            return validateStatus(ret);
        });
    }

    setMode(mode: "autonom" | "devin-cloud"): Promise<RuntimeStatus>
    {
        return this.serialize(async () =>
        {
            if (!this.client?.connected)
                throw new Error("Attach the native Command Center before changing mode.");
            const ret = await this.evaluate(this.client, statusExpression(
                `globalThis.__autonomCenter?.owner===${JSON.stringify(this.identity)}`
                + `?globalThis.__autonomCenter.setMode(${JSON.stringify(mode)}):null`));
            if (ret === null)
            {
                this.disconnect();
                throw new Error("The native Command Center runtime is gone. Attach again before changing mode.");
            }
            return validateStatus(ret);
        });
    }

    private serialize<Value>(action: () => Promise<Value>): Promise<Value>
    {
        const ret = this.pending.then(action);
        this.pending = ret.then(() =>
        {
        }, () =>
        {
        });
        return ret;
    }

    private async apply(content: CenterContent): Promise<RuntimeStatus>
    {
        await verifyBuild(this.appRoot);
        this.patchOnlyIntegrityNoticeSuppressed = await verifyPatchOnlyWarningCase(this.appRoot);
        if (!this.client?.connected)
        {
            this.disconnect();
            this.client = await this.discover();
        }
        const client = this.client;
        let failed = true;
        try
        {
            const owner = await this.evaluate(client, "globalThis.__autonomCenter?.owner??null");
            if (owner !== null && owner !== this.identity)
                throw new Error("The native Command Center belongs to another extension activation.");
            let ret: unknown;
            if (owner === this.identity)
            {
                ret = await this.evaluate(client, statusExpression(
                    `globalThis.__autonomCenter.update(${JSON.stringify(content)},`
                    + `${this.patchOnlyIntegrityNoticeSuppressed})`));
            }
            else
            {
                await this.evaluate(client, `globalThis.__autonomAttachProbe=(${probe.toString()})();`
                    + "Boolean(globalThis.__autonomAttachProbe)");
                await this.captureServices(client);
                ret = await this.evaluate(client, this.runtimeCode + ";" + statusExpression(
                    `AutonomNative.install(globalThis.__autonomServices,${JSON.stringify(this.identity)},`
                    + `${this.patchOnlyIntegrityNoticeSuppressed}).update(${JSON.stringify(content)},`
                    + `${this.patchOnlyIntegrityNoticeSuppressed})`));
            }
            ret = validateStatus(ret);
            failed = false;
            this.startHeartbeat();
            return ret as RuntimeStatus;
        }
        finally
        {
            try
            {
                if (client.connected)
                    await this.clearTemporary(client);
            }
            catch (error)
            {
                failed = true;
                throw error;
            }
            finally
            {
                if (failed)
                    this.disconnect();
            }
        }
    }

    /**
     * Finds the one renderer whose extension host reports this activation's
     * identity. Fails closed when zero or multiple windows match, and cleans up
     * the temporary probe reference in every window it touches.
     */
    private async discover(): Promise<CdpClient>
    {
        const matches: CdpClient[] = [];
        try
        {
            for (const address of await targetSockets(this.appRoot, this.port))
            {
                const client = await CdpClient.connect(address, this.port);
                let matched = false;
                try
                {
                    const identity = await this.evaluate(client,
                        `globalThis.__autonomAttachProbe=(${probe.toString()})();`
                        + "globalThis.__autonomAttachProbe?.api.executeCommand('autonomCenter.bridgeIdentity')");
                    matched = identity === this.identity;
                    if (matched)
                        matches.push(client);
                }
                finally
                {
                    try
                    {
                        if (client.connected)
                            await this.evaluate(client, "delete globalThis.__autonomAttachProbe;");
                    }
                    finally
                    {
                        if (!matched)
                            client.close();
                    }
                }
            }
            if (matches.length !== 1)
                throw new Error(matches.length > 1 ? "Multiple Desktop windows reported this activation identity."
                    : "Prepare the native Command Center first, then attach in this Desktop window.");
            return matches[0]!;
        }
        catch (error)
        {
            for (const client of matches)
                client.close();
            throw error;
        }
    }

    private async evaluate(client: CdpClient, expression: string): Promise<unknown>
    {
        const group = `autonom-center-${++this.objectSequence}`;
        try
        {
            const ret = await client.request("Runtime.evaluate", {
                expression,
                objectGroup: group,
                returnByValue: true,
                awaitPromise: true,
            });
            if (ret.exceptionDetails || !ret.result)
                throw new Error("The native Command Center renderer operation failed.");
            return ret.result.value;
        }
        finally
        {
            if (client.connected)
                await client.request("Runtime.releaseObjectGroup", { objectGroup: group });
        }
    }

    private async clearTemporary(client: CdpClient): Promise<void>
    {
        if (client.connected)
            await this.evaluate(client, "delete globalThis.__autonomAttachProbe;delete globalThis.__autonomServices;");
    }

    /**
     * Captures the native navigation service references by briefly pausing the
     * renderer at two known native calls.
     *
     * This is the only operation that pauses the renderer, it lasts
     * milliseconds, and it runs once per attachment. Every breakpoint is
     * removed and the renderer is resumed in a `finally`, including on error.
     */
    private async captureServices(client: CdpClient): Promise<void>
    {
        const group = `autonom-capture-${++this.objectSequence}`;
        try
        {
            await client.request("Debugger.enable", { maxScriptsCacheSize: 0 });
            await this.capture(
                client,
                group,
                "getDesktopNavSurfacesSnapshot",
                "globalThis.__autonomServices={manifest:this._manifestService,controller:yAe.prototype};true",
            );
            await this.capture(
                client,
                group,
                "getActiveDesktopNavSurfaceSnapshot",
                "globalThis.__autonomServices.groups=o;globalThis.__autonomServices.windowId=e.vscodeWindowId;"
                    + "globalThis.__autonomServices.api=globalThis.__autonomAttachProbe.api;true",
            );
        }
        finally
        {
            if (client.connected)
            {
                try
                {
                    await client.request("Debugger.disable");
                }
                finally
                {
                    await client.request("Runtime.releaseObjectGroup", { objectGroup: group });
                }
            }
        }
    }

    private async capture(
        client: CdpClient,
        group: string,
        functionName: string,
        assignments: string,
    ): Promise<void>
    {
        const expression = `globalThis.__autonomAttachProbe.props.${functionName}`;
        const reference = await client.request("Runtime.evaluate", { expression, objectGroup: group });
        if (reference.exceptionDetails || !reference.result?.objectId || reference.result.type !== "function")
            throw new Error("Prepare the native Command Center first; its sidebar services are unavailable.");
        const breakpoint = await client.request("Debugger.setBreakpointOnFunctionCall", {
            objectId: reference.result.objectId,
        });
        if (typeof breakpoint.breakpointId !== "string")
            throw new Error("The native service capture breakpoint was not installed.");
        let paused = false;
        let cleanup: Promise<void> | null = null;
        const finish = (): Promise<void> =>
        {
            if (!cleanup)
            {
                cleanup = (async () =>
                {
                    try
                    {
                        if (client.connected)
                            await client.request("Debugger.removeBreakpoint", {
                                breakpointId: breakpoint.breakpointId,
                            });
                    }
                    finally
                    {
                        if (paused && client.connected)
                            await client.request("Debugger.resume");
                    }
                })();
            }
            return cleanup;
        };
        let removeListener = () =>
        {
        };
        let timer: ReturnType<typeof setTimeout> | undefined;
        const captured = new Promise<void>((resolve, reject) =>
        {
            timer = setTimeout(() =>
            {
                reject(new Error("Timed out capturing native Command Center services."));
            }, REQUEST_TIMEOUT);
            removeListener = client.on("Debugger.paused", (parameters) =>
            {
                if (paused || !Array.isArray(parameters.hitBreakpoints)
                    || !parameters.hitBreakpoints.includes(breakpoint.breakpointId))
                    return;
                paused = true;
                void (async () =>
                {
                    try
                    {
                        const frame = parameters.callFrames?.[0]?.callFrameId;
                        if (typeof frame !== "string")
                            throw new Error("The native service capture has no call frame.");
                        try
                        {
                            const ret = await client.request("Debugger.evaluateOnCallFrame", {
                                callFrameId: frame,
                                expression: assignments,
                                objectGroup: group,
                                returnByValue: true,
                            });
                            if (ret.exceptionDetails)
                                throw new Error("The native Command Center service capture failed.");
                        }
                        finally
                        {
                            await finish();
                        }
                        resolve();
                    }
                    catch (error)
                    {
                        try
                        {
                            await finish();
                        }
                        catch
                        {
                        }
                        reject(error);
                    }
                })();
            });
        });
        try
        {
            await Promise.all([
                captured,
                client.request("Runtime.evaluate", { expression: `${expression}()`, objectGroup: group }).then((ret) =>
                {
                    if (ret.exceptionDetails)
                        throw new Error("The native Command Center snapshot call failed.");
                }),
            ]);
        }
        finally
        {
            clearTimeout(timer);
            removeListener();
            await finish();
        }
    }

    /**
     * Keeps the renderer runtime alive and re-validates the suppression state.
     *
     * If the socket drops or the runtime is no longer owned by this activation,
     * the client detaches. The runtime itself expires after a missed lease, so a
     * crashed extension host cannot leave native behavior patched.
     */
    private startHeartbeat(): void
    {
        if (this.heartbeat)
            return;
        this.heartbeat = setInterval(() =>
        {
            if (this.heartbeatPending)
                return;
            this.heartbeatPending = true;
            void this.serialize(async () =>
            {
                const client = this.client;
                if (!client?.connected)
                {
                    this.disconnect();
                    return;
                }
                try
                {
                    const ret = await this.evaluate(client, `(function(){const runtime=globalThis.__autonomCenter;`
                        + `if(runtime?.owner!==${JSON.stringify(this.identity)})return false;`
                        + `runtime.heartbeat(${JSON.stringify(this.identity)},`
                        + `${this.patchOnlyIntegrityNoticeSuppressed});return true;})()`);
                    if (ret !== true)
                        this.disconnect();
                }
                catch
                {
                    this.disconnect();
                }
            }).finally(() =>
            {
                this.heartbeatPending = false;
            });
        }, 5000);
        this.heartbeat.unref();
    }

    private stopHeartbeat(): void
    {
        if (this.heartbeat)
            clearInterval(this.heartbeat);
        this.heartbeat = null;
    }

    private disconnect(): void
    {
        this.stopHeartbeat();
        this.client?.close();
        this.client = null;
    }
}
