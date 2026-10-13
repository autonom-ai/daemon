import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";

export interface BundleConfig {
    id: "workbench" | "sessions";
    displayName: string;
    bundleRelPath: string;
    jsxVar: string;
    hook1Slot: string;
    hook2Slot?: string | undefined;
    hook3Slot?: string | undefined;
    htmlRelPath?: string | undefined;
    /** Full replacement inserted for hook2Slot: the React-owned sidebar slot before the native sidebar; native children after the slot are hidden by a CSS sibling rule in Autonom mode. */
    hook2Patched?: string | undefined;
    /** Full replacement inserted for hook3Slot: the React-owned center slot and the native center wrapper. */
    hook3Patched?: string | undefined;
    /** Legacy V1/V2 fragments that must be reversed to reconstruct a pristine bundle: [patched, original]. */
    legacy?: { hook1: [string, string]; hook2: [string, string]; hook3: [string, string] } | undefined;
}

export interface BundleStatus {
    id: "workbench" | "sessions";
    displayName: string;
    path: string;
    available: boolean;
    patched: boolean;
    writable: boolean;
    hasBackup: boolean;
    error?: string | undefined;
}

export interface PatchStatus {
    available: boolean;
    patched: boolean;
    writable: boolean;
    hasBackup: boolean;
    appRoot: string;
    sessionsDir: string;
    bundles?: BundleStatus[] | undefined;
    error?: string | undefined;
}

export interface PatchResult {
    applied: boolean;
    alreadyPatched?: boolean | undefined;
    writable?: boolean | undefined;
    error?: string | undefined;
    bundles?: { id: string; applied: boolean; alreadyPatched?: boolean | undefined; error?: string | undefined }[] | undefined;
}

export interface RestoreResult {
    restored: boolean;
    error?: string | undefined;
    bundles?: { id: string; restored: boolean; error?: string | undefined }[] | undefined;
}

export const MARKER_V1 = "/*__AUTONOM_PATCH_V1__*/";
export const MARKER_V2 = "/*__AUTONOM_PATCH_V2__*/";
export const MARKER_V3 = "/*__AUTONOM_PATCH_V3__*/";
export const MARKER_V4 = "/*__AUTONOM_PATCH_V4__*/";
export const MARKER_P1 = "/*__AUTONOM_P1__*/";
export const MARKER_P2 = "/*__AUTONOM_P2__*/";
export const MARKER_P3 = "/*__AUTONOM_P3__*/";
export const MARKER_TOGGLE = "/*__autonom_provider_toggle*/";
export const VENDOR_HOOK_SLOT = '_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session"';

export const WORKBENCH_BUNDLE_CONFIG: BundleConfig = {
    id: "workbench",
    displayName: "Workbench In-App Agent Client",
    bundleRelPath: path.join("out", "vs", "workbench", "windsurf-chat-client", "index.js"),
    jsxVar: "tX",
    hook1Slot: 'tX.jsx)(rNj,{children:(0,tX.jsxs)(rNG,{ariaLabel:"New session"',
    hook2Slot: 'children:[tg,(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces"',
    hook3Slot: 'children:[(0,tX.jsx)(iqs,{}),(0,tX.jsx)(ewt,{})]',
    hook2Patched: 'children:[tg,(0,tX.jsx)("div",{className:"autonom-slot-sidebar",ref:globalThis.__autonom?.sidebarSlot,"data-autonom-slot":"sidebar"}),(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces"',
    hook3Patched: 'children:[(0,tX.jsx)(iqs,{}),(0,tX.jsxs)(tX.Fragment,{children:[(0,tX.jsx)("div",{className:"autonom-slot-center",ref:globalThis.__autonom?.centerSlot,"data-autonom-slot":"center"}),(0,tX.jsx)("div",{className:"autonom-native-center","data-autonom-slot":"native-center",children:(0,tX.jsx)(ewt,{})})]})]',
    legacy: {
        hook1: ['(globalThis.__autonom?.wrapNewSession?.(tX)??tX.jsx))', 'tX.jsx)'],
        hook2: ['children:[tg,globalThis.__autonom?.isAutonomActive?.()?globalThis.__autonom?.renderSidebar?.(tX):(0,tX.jsx)(rNR,{', 'children:[tg,(0,tX.jsx)(rNR,{'],
        hook3: ['children:[(0,tX.jsx)(iqs,{}),(globalThis.__autonom?.isAutonomActive?.()&&globalThis.__autonom?.renderCenter?.(tX))||(0,tX.jsx)(ewt,{})]', 'children:[(0,tX.jsx)(iqs,{}),(0,tX.jsx)(ewt,{})]'],
    },
    htmlRelPath: path.join("out", "vs", "code", "electron-browser", "workbench", "workbench.html"),
};

export const SESSIONS_BUNDLE_CONFIG: BundleConfig = {
    id: "sessions",
    displayName: "Standalone Sessions Window",
    bundleRelPath: path.join("out", "vs", "sessions", "sessions.desktop.main.js"),
    jsxVar: "_",
    hook1Slot: '_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session"',
    hook2Slot: 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"',
    hook3Slot: 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]',
    hook2Patched: 'children:[jY,(0,_.jsx)("div",{className:"autonom-slot-sidebar",ref:globalThis.__autonom?.sidebarSlot,"data-autonom-slot":"sidebar"}),(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"',
    hook3Patched: 'children:[(0,_.jsx)(vsu,{}),(0,_.jsxs)(_.Fragment,{children:[(0,_.jsx)("div",{className:"autonom-slot-center",ref:globalThis.__autonom?.centerSlot,"data-autonom-slot":"center"}),(0,_.jsx)("div",{className:"autonom-native-center","data-autonom-slot":"native-center",children:(0,_.jsx)(WTr,{})})]})]',
    legacy: {
        hook1: ['(globalThis.__autonom?.wrapNewSession?.(_)??_.jsx))', '_.jsx)'],
        hook2: ['children:[jY,globalThis.__autonom?.isAutonomActive?.()?globalThis.__autonom?.renderSidebar?.(_):(0,_.jsx)(eft,{', 'children:[jY,(0,_.jsx)(eft,{'],
        hook3: ['children:[(0,_.jsx)(vsu,{}),(globalThis.__autonom?.isAutonomActive?.()&&globalThis.__autonom?.renderCenter?.(_))||(0,_.jsx)(WTr,{})]', 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]'],
    },
    htmlRelPath: path.join("out", "vs", "sessions", "electron-browser", "sessions.html"),
};

export const TARGET_BUNDLES: BundleConfig[] = [WORKBENCH_BUNDLE_CONFIG, SESSIONS_BUNDLE_CONFIG];

export function computeSha256(data: string | Buffer): string {
    return createHash("sha256").update(data).digest("hex");
}

export function computeProductChecksum(buffer: Buffer | string): string {
    const buf = typeof buffer === "string" ? Buffer.from(buffer, "utf8") : buffer;
    return createHash("sha256").update(buf).digest("base64").replace(/=+$/, "");
}

/**
 * Self-contained inline micro-hook bootstrap.
 *
 * The bootstrap is the only injected code that touches the vendor React tree. It defines
 * globalThis.__autonom synchronously, renders the provider switch around the native New
 * session item, hands the companion two stable React-owned slots (sidebar and center),
 * and controls provider/center visibility purely through <html> data attributes and a
 * stylesheet, so React re-renders can never wipe the visibility state.
 *
 * No raw innerHTML/outerHTML/document.write sinks (Trusted Types safe).
 */
export const BOOTSTRAP_HEADER = `${MARKER_V4}/* Autonom Command Center Micro-Hook (PoC) */
(function(){
if(globalThis.__autonom&&globalThis.__autonom.version>=4)return;
var m={};
function g(k,d){try{return(typeof localStorage!=="undefined"&&localStorage.getItem(k))||m[k]||d;}catch{return m[k]||d;}}
function s(k,v){try{if(typeof localStorage!=="undefined")localStorage.setItem(k,v);}catch{} m[k]=v;}
var slots={sidebar:null,center:null};
var slotListener=null;
var providerListeners=new Set();
var errors=[];
function normalized(v){return v==="devin-cloud"?"devin-cloud":"autonom";}
function applyProvider(v){
s("autonom.provider",v);
if(typeof document!=="undefined"){
document.documentElement.dataset.autonomProvider=v;
var buttons=document.querySelectorAll("[data-provider]");
for(var i=0;i<buttons.length;i++){
var button=buttons[i];
var active=button.getAttribute("data-provider")===v;
button.setAttribute("aria-pressed",String(active));
if(active){button.classList.add("active");}else{button.classList.remove("active");}
}
}
}
function showError(message){
errors.push(message);
try{console.error("[Autonom] "+message);}catch{}
var el=slots.sidebar;
if(el&&typeof document!=="undefined"){
var box=document.createElement("div");
box.className="command-center-error";
box.textContent="Autonom Command Center failed to load: "+message;
el.replaceChildren(box);
}
}
var a={
version:4,
slots:slots,
errors:errors,
get provider(){return normalized(g("autonom.provider","autonom"));},
set provider(v){applyProvider(normalized(v));for(var c of providerListeners){try{c(this.provider);}catch{}}if(typeof window!=="undefined")window.dispatchEvent(new CustomEvent("autonom:provider-changed",{detail:{provider:this.provider}}));},
setProvider:function(v){this.provider=v;},
subscribe:function(c){providerListeners.add(c);return function(){providerListeners.delete(c);};},
isAutonomActive:function(){return this.provider!=="devin-cloud";},
onSlots:function(c){slotListener=c;try{c(slots);}catch(e){}},
notifySlots:function(){if(slotListener){try{slotListener(slots);}catch(e){}}},
sidebarSlot:function(el){
if(slots.sidebar===el)return;
slots.sidebar=el;
if(el&&errors.length>0&&!el.firstChild)showError(errors[0]);
a.notifySlots();
},
centerSlot:function(el){slots.center=el;},
setCenterOpen:function(open){
if(typeof document==="undefined")return;
if(open){document.documentElement.dataset.autonomCenter="open";}
else{delete document.documentElement.dataset.autonomCenter;}
},
wrapNewSession:function(jsxRuntime){
return function(n,p,k){
var r=jsxRuntime||globalThis._||globalThis.tX;
if(!r)return null;
var on=a.isAutonomActive();
function segment(value,label){
return r.jsx("button",{type:"button","data-provider":value,"aria-pressed":String(value==="autonom"?on:!on),className:"switch-segment"+(value==="autonom"?on:!on?" active":""),onClick:function(){a.setProvider(value);},children:r.jsx("span",{className:"segment-label",children:label})});
}
var t=r.jsx("li",{"data-slot":"sidebar-menu-item",className:"mb-2 mt-1",key:"__autonom_provider_toggle_item",children:r.jsx("div",{className:"agent-editor-switch autonom-provider-switch",children:r.jsx("div",{className:"switch-container",children:[segment("autonom","Autonom"),segment("devin-cloud","Devin Cloud")]})})});
var o=r.jsx(n,p,k);
return r.jsxs(r.Fragment||"div",{key:"__autonom_new_session_slot",children:[t,o]});
};
}
};
globalThis.__autonom=a;
applyProvider(a.provider);
if(typeof document!=="undefined"){
if(!document.getElementById("autonom-command-center-style")){
var st=document.createElement("style");
st.id="autonom-command-center-style";
st.appendChild(document.createTextNode("[data-autonom-slot=sidebar],[data-autonom-slot=center],[data-autonom-slot=native-center]{display:contents}.autonom-provider-switch{display:flex;width:100%}.autonom-provider-switch .switch-container{width:100%}.autonom-provider-switch .switch-segment{flex:1 1 50%;min-width:0}html[data-autonom-provider=autonom] [data-autonom-slot=sidebar]~*{display:none!important}html[data-autonom-provider=devin-cloud] [data-autonom-slot=sidebar]{display:none!important}html[data-autonom-center=open] [data-autonom-slot=native-center]{display:none!important}html:not([data-autonom-center=open]) [data-autonom-slot=center]{display:none!important}html[data-autonom-provider=devin-cloud] [data-autonom-slot=center]{display:none!important}html[data-autonom-provider=devin-cloud] [data-autonom-slot=native-center]{display:contents!important}"));
document.head.appendChild(st);
}
if(!document.getElementById("autonom-companion-style")){
var lk=document.createElement("link");
lk.id="autonom-companion-style";
lk.rel="stylesheet";
lk.href=globalThis._VSCODE_FILE_ROOT?new URL("vs/sessions/autonom.sessions.css",globalThis._VSCODE_FILE_ROOT).href:"./autonom.sessions.css";
document.head.appendChild(lk);
}
}
var loadedVersion=null;
var firstVersionPoll=true;
function companionUrl(version){
var base=globalThis._VSCODE_FILE_ROOT?new URL("vs/sessions/autonom.bundle.js",globalThis._VSCODE_FILE_ROOT).href:"./autonom.bundle.js";
return version?base+"?v="+encodeURIComponent(version):base;
}
function loadCompanion(version){
import(companionUrl(version)).then(function(mod){
if(mod&&typeof mod.init==="function"){mod.init(globalThis);}
else{showError("companion bundle has no init export");}
}).catch(function(e){showError(String(e&&e.message||e));});
}
loadCompanion(null);
var versionUrl=globalThis._VSCODE_FILE_ROOT?new URL("vs/sessions/autonom.version.json",globalThis._VSCODE_FILE_ROOT).href:null;
if(versionUrl&&typeof fetch==="function"){
setInterval(function(){
fetch(versionUrl,{cache:"no-store"}).then(function(res){return res.ok?res.json():null;}).then(function(data){
if(!data||typeof data.version!=="string")return;
if(firstVersionPoll){firstVersionPoll=false;loadedVersion=data.version;return;}
if(data.version!==loadedVersion){loadedVersion=data.version;loadCompanion(data.version);}
}).catch(function(){});
},2000);
}
})();
`;

export class PatchManager {
    private readonly appRoot: string;
    private readonly sessionsDir: string;
    private readonly mainJsPath: string;
    private readonly htmlPath: string;
    private readonly backupPath: string;
    private readonly htmlBackupPath: string;
    private readonly context?: any;

    constructor(appRootOrContext?: string | any) {
        if (typeof appRootOrContext === "string") {
            this.appRoot = appRootOrContext;
        } else if (appRootOrContext && typeof appRootOrContext === "object") {
            this.context = appRootOrContext;
            let detectedRoot = "";
            try {
                // eslint-disable-next-line @typescript-eslint/no-require-imports
                const vscode = require("vscode");
                detectedRoot = vscode.env?.appRoot || "";
            } catch {
                detectedRoot = "";
            }
            this.appRoot = detectedRoot || appRootOrContext.extensionUri?.fsPath || (typeof appRootOrContext.asAbsolutePath === "function" ? appRootOrContext.asAbsolutePath("") : "") || "";
        } else {
            let detectedRoot = "";
            try {
                // eslint-disable-next-line @typescript-eslint/no-require-imports
                const vscode = require("vscode");
                detectedRoot = vscode.env?.appRoot || "";
            } catch {
                detectedRoot = "";
            }
            this.appRoot = detectedRoot;
        }

        this.sessionsDir = path.join(this.appRoot, "out", "vs", "sessions");
        this.mainJsPath = path.join(this.sessionsDir, "sessions.desktop.main.js");
        this.htmlPath = path.join(this.sessionsDir, "electron-browser", "sessions.html");
        this.backupPath = `${this.mainJsPath}.autonom.orig`;
        this.htmlBackupPath = `${this.htmlPath}.autonom.orig`;
    }

    public computeProductChecksum(buffer: Buffer | string): string {
        return computeProductChecksum(buffer);
    }

    public isDirectoryWritable(dirPath: string): boolean {
        if (!dirPath || !fs.existsSync(dirPath)) {
            return false;
        }
        try {
            fs.accessSync(dirPath, fs.constants.W_OK);
            return true;
        } catch {
            return false;
        }
    }

    public resolveBackupPath(config: BundleConfig, fullPath: string): string {
        const primary = `${fullPath}.autonom.orig`;
        if (fs.existsSync(primary)) {
            return primary;
        }

        const dirName = path.basename(path.dirname(fullPath));
        const baseName = path.basename(fullPath);
        const fallback1 = this.sessionsDir ? path.join(this.sessionsDir, `${dirName}.${baseName}.autonom.orig`) : "";
        if (fallback1 && fs.existsSync(fallback1)) {
            return fallback1;
        }

        const fallback2 = this.sessionsDir ? path.join(this.sessionsDir, `${config.id}.${baseName}.autonom.orig`) : "";
        if (fallback2 && fs.existsSync(fallback2)) {
            return fallback2;
        }

        const parentDir = path.dirname(fullPath);
        if (this.isDirectoryWritable(parentDir)) {
            return primary;
        }

        if (this.sessionsDir) {
            return fallback1 || fallback2;
        }

        return primary;
    }

    public getProductJsonPath(): string {
        if (this.appRoot) {
            return path.join(this.appRoot, "product.json");
        }
        if (this.sessionsDir) {
            const derivedAppRoot = path.resolve(this.sessionsDir, "..", "..", "..");
            return path.join(derivedAppRoot, "product.json");
        }
        return "/usr/share/devin-desktop/resources/app/product.json";
    }

    public normalizeProductRelPath(relOrFullPath: string): string {
        let normalized = relOrFullPath.split(path.sep).join("/");
        const outIdx = normalized.indexOf("/out/");
        if (outIdx !== -1) {
            normalized = normalized.slice(outIdx + 5);
        } else if (normalized.startsWith("out/")) {
            normalized = normalized.slice(4);
        }
        return normalized;
    }

    public syncProductChecksums(patchedMap: Map<string, Buffer>): void {
        const productPath = this.getProductJsonPath();
        if (!fs.existsSync(productPath)) {
            return;
        }

        try {
            const raw = fs.readFileSync(productPath, "utf8");
            const product = JSON.parse(raw);
            if (!product.checksums || typeof product.checksums !== "object") {
                product.checksums = {};
            }

            const origBackupPath = this.sessionsDir ? path.join(this.sessionsDir, "product.checksums.orig.json") : "";
            if (origBackupPath && fs.existsSync(this.sessionsDir) && !fs.existsSync(origBackupPath)) {
                const origMap: Record<string, string> = {};
                for (const relPath of patchedMap.keys()) {
                    const normPath = this.normalizeProductRelPath(relPath);
                    if (product.checksums[normPath]) {
                        origMap[normPath] = product.checksums[normPath];
                    }
                }
                try {
                    fs.writeFileSync(origBackupPath, JSON.stringify(origMap, null, "\t") + "\n", "utf8");
                } catch {
                    // Ignore if unwritable
                }
            }

            let modified = false;
            for (const [relPath, buffer] of patchedMap.entries()) {
                const normPath = this.normalizeProductRelPath(relPath);
                const checksum = computeProductChecksum(buffer);
                if (product.checksums[normPath] !== checksum) {
                    product.checksums[normPath] = checksum;
                    modified = true;
                }
            }

            if (modified) {
                fs.writeFileSync(productPath, JSON.stringify(product, null, "\t") + "\n", "utf8");
            }
        } catch {
            // Do not crash on non-fatal product.json read/parse/write errors
        }
    }

    public restoreProductChecksums(relPaths: string[]): void {
        const productPath = this.getProductJsonPath();
        if (!fs.existsSync(productPath)) {
            return;
        }

        try {
            const raw = fs.readFileSync(productPath, "utf8");
            const product = JSON.parse(raw);
            if (!product.checksums || typeof product.checksums !== "object") {
                return;
            }

            const origBackupPath = this.sessionsDir ? path.join(this.sessionsDir, "product.checksums.orig.json") : "";
            let origMap: Record<string, string> = {};
            if (origBackupPath && fs.existsSync(origBackupPath)) {
                try {
                    origMap = JSON.parse(fs.readFileSync(origBackupPath, "utf8"));
                } catch {
                    origMap = {};
                }
            }

            let modified = false;
            for (const relPath of relPaths) {
                const normPath = this.normalizeProductRelPath(relPath);
                let origChecksum = origMap[normPath];

                if (!origChecksum) {
                    const fullTarget = path.join(this.appRoot || path.join(this.sessionsDir, "..", ".."), "out", normPath);
                    if (fs.existsSync(fullTarget)) {
                        origChecksum = computeProductChecksum(fs.readFileSync(fullTarget));
                    }
                }

                if (origChecksum && product.checksums[normPath] !== origChecksum) {
                    product.checksums[normPath] = origChecksum;
                    modified = true;
                }
            }

            if (modified) {
                fs.writeFileSync(productPath, JSON.stringify(product, null, "\t") + "\n", "utf8");
            }

            if (origBackupPath && fs.existsSync(origBackupPath)) {
                try {
                    fs.unlinkSync(origBackupPath);
                } catch {}
            }
        } catch {
            // Do not crash on non-fatal product.json read/parse/write errors
        }
    }

    public getTargetBundles(): { config: BundleConfig; fullPath: string; backupPath: string; dirPath: string }[] {
        const wbPath = this.appRoot
            ? path.join(this.appRoot, WORKBENCH_BUNDLE_CONFIG.bundleRelPath)
            : path.join(this.sessionsDir, "..", "workbench", "windsurf-chat-client", "index.js");
        const sessPath = this.mainJsPath;

        const wbBackup = this.resolveBackupPath(WORKBENCH_BUNDLE_CONFIG, wbPath);
        const sessBackup = this.backupPath || this.resolveBackupPath(SESSIONS_BUNDLE_CONFIG, sessPath);

        return [
            {
                config: WORKBENCH_BUNDLE_CONFIG,
                fullPath: wbPath,
                backupPath: wbBackup,
                dirPath: path.dirname(wbPath),
            },
            {
                config: SESSIONS_BUNDLE_CONFIG,
                fullPath: sessPath,
                backupPath: sessBackup,
                dirPath: this.sessionsDir || path.dirname(sessPath),
            },
        ];
    }

    public getTargetPath(): string {
        const available = this.getTargetBundles().filter((t) => fs.existsSync(t.fullPath));
        if (available.length > 0) {
            const sessionsTarget = available.find((t) => t.config.id === "sessions");
            const first = available[0];
            return sessionsTarget ? sessionsTarget.fullPath : (first ? first.fullPath : this.mainJsPath);
        }
        return this.mainJsPath;
    }

    public getBackupPath(): string {
        return this.backupPath || `${this.getTargetPath()}.autonom.orig`;
    }

    public getSessionsDir(): string {
        return this.sessionsDir;
    }

    public getWorkbenchCompanionDir(): string {
        return this.appRoot
            ? path.dirname(path.join(this.appRoot, WORKBENCH_BUNDLE_CONFIG.bundleRelPath))
            : path.join(this.sessionsDir, "..", "workbench", "windsurf-chat-client");
    }

    /** Version of the currently deployed companion, used by live pages to hot-load new builds. */
    public async readCompanionVersion(): Promise<string | undefined> {
        try {
            const raw = await fs.promises.readFile(path.join(this.sessionsDir, "autonom.version.json"), "utf8");
            const parsed = JSON.parse(raw) as { version?: string };
            return parsed.version;
        } catch {
            return undefined;
        }
    }

    public async isWritable(filePath: string): Promise<boolean> {
        try {
            await fs.promises.access(filePath, fs.constants.W_OK);
            return true;
        } catch {
            return false;
        }
    }

    public async checkStatus(): Promise<PatchStatus> {
        const targets = this.getTargetBundles();
        const availableTargets = targets.filter((t) => fs.existsSync(t.fullPath));

        if (availableTargets.length === 0) {
            return {
                available: false,
                patched: false,
                writable: false,
                hasBackup: false,
                appRoot: this.appRoot,
                sessionsDir: this.sessionsDir,
                error: "Devin Desktop bundles not found.",
            };
        }

        const bundleStatuses: BundleStatus[] = [];
        let allPatched = true;
        let allWritable = true;
        let hasAnyBackup = false;
        let firstUnwritableError = "";

        for (const t of availableTargets) {
            const writable = await this.isWritable(t.fullPath);
            const hasBackup = fs.existsSync(t.backupPath);
            const patched = await this.isBundlePatched(t.fullPath, t.config);

            if (!patched) allPatched = false;
            if (!writable) {
                allWritable = false;
                if (!firstUnwritableError) {
                    firstUnwritableError = `Write permission denied for ${t.fullPath}. Use the supported Devin Desktop installation permission mechanism, then retry.`;
                }
            }
            if (hasBackup) hasAnyBackup = true;

            bundleStatuses.push({
                id: t.config.id,
                displayName: t.config.displayName,
                path: t.fullPath,
                available: true,
                patched,
                writable,
                hasBackup,
                error: writable ? undefined : `Write permission denied for ${t.fullPath}`,
            });
        }

        return {
            available: true,
            patched: allPatched,
            writable: allWritable,
            hasBackup: hasAnyBackup,
            appRoot: this.appRoot,
            sessionsDir: this.sessionsDir,
            bundles: bundleStatuses,
            error: firstUnwritableError || undefined,
        };
    }

    private async isBundlePatched(filePath: string, config: BundleConfig): Promise<boolean> {
        if (!fs.existsSync(filePath)) {
            return false;
        }
        try {
            const content = await fs.promises.readFile(filePath, "utf8");
            const markers = [MARKER_V4, MARKER_P1, MARKER_TOGGLE];
            if (config.hook2Slot) markers.push(MARKER_P2);
            if (config.hook3Slot) markers.push(MARKER_P3);
            return markers.every((marker) => content.includes(marker));
        } catch {
            return false;
        }
    }

    public async isPatched(): Promise<boolean> {
        const targets = this.getTargetBundles();
        const available = targets.filter((t) => fs.existsSync(t.fullPath));
        if (available.length === 0) {
            return false;
        }
        const results = await Promise.all(available.map((t) => this.isBundlePatched(t.fullPath, t.config)));
        return results.every(Boolean);
    }

    /**
     * Reconstructs a pristine vendor bundle from a known Autonom patch generation by
     * stripping the bootstrap prefix and reversing the exact surgical hook replacements.
     * Returns undefined when the content is not a recognized patch generation.
     */
    public reconstructPristine(content: string, config: BundleConfig): string | undefined {
        let body = content;
        if (body.startsWith("/*__AUTONOM_PATCH_")) {
            const bootstrapEnd = body.indexOf("})();\n");
            if (bootstrapEnd < 0 || bootstrapEnd > 20000) {
                return undefined;
            }
            const rest = body.slice(bootstrapEnd + "})();\n".length);
            if (!rest.startsWith("/*!")) {
                return undefined;
            }
            body = rest;
        }
        if (config.legacy) {
            const [legacyHook1Patched, legacyHook1Original] = config.legacy.hook1;
            body = body.replace(legacyHook1Patched, legacyHook1Original);
            const [legacyHook2Patched, legacyHook2Original] = config.legacy.hook2;
            body = body.replace(legacyHook2Patched, legacyHook2Original);
            const [legacyHook3Patched, legacyHook3Original] = config.legacy.hook3;
            body = body.replace(legacyHook3Patched, legacyHook3Original);
        }
        if (config.hook2Patched && config.hook2Slot) {
            body = body.replace(config.hook2Patched, config.hook2Slot);
        }
        if (config.hook3Patched && config.hook3Slot) {
            body = body.replace(config.hook3Patched, config.hook3Slot);
        }
        for (const marker of [MARKER_V1, MARKER_V2, MARKER_V3, MARKER_V4, MARKER_P1, MARKER_P2, MARKER_P3, MARKER_TOGGLE]) {
            body = body.split(marker).join("");
        }
        if (body.includes("__autonom") || body.includes("AUTONOM_PATCH") || body.includes("AUTONOM_P")) {
            return undefined;
        }
        if (!body.includes(config.hook1Slot)) {
            return undefined;
        }
        return body;
    }

    private applyHooks(content: string, config: BundleConfig): { patched: string; error?: string } {
        let patched = content;
        if (!patched.includes(config.hook1Slot)) {
            return { patched, error: `Vendor hook slot not found in ${config.id} bundle.` };
        }
        const hook1Target = config.hook1Slot;
        const slotSuffix = hook1Target.slice(hook1Target.indexOf("(") + 1);
        const hook1Replacement = `${MARKER_P1}${MARKER_TOGGLE}(globalThis.__autonom?.wrapNewSession?.(${config.jsxVar})??${config.jsxVar}.jsx))(${slotSuffix}`;
        patched = patched.replace(hook1Target, hook1Replacement);

        if (config.hook2Slot && config.hook2Patched) {
            if (!patched.includes(config.hook2Slot)) {
                return { patched, error: `Sidebar hook slot not found in ${config.id} bundle.` };
            }
            patched = patched.replace(config.hook2Slot, `${MARKER_P2}${config.hook2Patched}`);
        }

        if (config.hook3Slot && config.hook3Patched) {
            if (!patched.includes(config.hook3Slot)) {
                return { patched, error: `Center hook slot not found in ${config.id} bundle.` };
            }
            patched = patched.replace(config.hook3Slot, `${MARKER_P3}${config.hook3Patched}`);
        }

        patched = BOOTSTRAP_HEADER + patched;
        return { patched };
    }

    public async ensurePatched(): Promise<PatchResult> {
        const targets = this.getTargetBundles();
        const available = targets.filter((t) => fs.existsSync(t.fullPath));

        if (available.length === 0) {
            return { applied: false, error: "Devin Desktop bundles not found in environment.", bundles: [] };
        }

        const writableTargets: typeof available = [];
        const unwritableTargets: typeof available = [];
        for (const t of available) {
            const writable = await this.isWritable(t.fullPath);
            if (writable) {
                writableTargets.push(t);
            } else {
                unwritableTargets.push(t);
            }
        }

        if (writableTargets.length === 0) {
            return {
                applied: false,
                writable: false,
                error: `Write permission denied for ${unwritableTargets.map((t) => t.fullPath).join(", ")}. Use the supported Devin Desktop installation permission mechanism, then retry.`,
                bundles: available.map((t) => ({
                    id: t.config.id,
                    applied: false,
                    error: `Write permission denied for ${t.fullPath}`,
                })),
            };
        }

        const targetsToPatch = writableTargets;
        const patchedBefore = new Map<typeof targetsToPatch[number], boolean>();
        for (const target of targetsToPatch) {
            patchedBefore.set(target, await this.isBundlePatched(target.fullPath, target.config));
        }
        let patchedAny = false;
        try {
            for (const target of targetsToPatch) {
                if (patchedBefore.get(target)) {
                    continue;
                }
                const content = await fs.promises.readFile(target.fullPath, "utf8");
                const hasLegacyMarkers = [MARKER_V1, MARKER_V2, MARKER_V3, MARKER_P1, MARKER_P2, MARKER_P3, MARKER_TOGGLE]
                    .some((marker) => content.includes(marker));
                if (hasLegacyMarkers) {
                    const pristine = this.reconstructPristine(content, target.config);
                    if (pristine === undefined) {
                        return {
                            applied: false,
                            error: `The existing Autonom patch in ${target.fullPath} could not be safely reconstructed for upgrade.`,
                            bundles: available.map((bundle) => ({ id: bundle.config.id, applied: false })),
                        };
                    }
                    const backupPath = target.backupPath;
                    await fs.promises.mkdir(path.dirname(backupPath), { recursive: true });
                    await fs.promises.writeFile(backupPath, pristine, "utf8");
                    await fs.promises.writeFile(target.fullPath, pristine, "utf8");
                }
            }

            await this.deployCompanion();

            for (const target of targetsToPatch) {
                if (patchedBefore.get(target)) {
                    continue;
                }
                const content = await fs.promises.readFile(target.fullPath, "utf8");
                const origSha = computeSha256(content);

                const { patched, error } = this.applyHooks(content, target.config);
                if (error) {
                    return {
                        applied: false,
                        error,
                        bundles: available.map((bundle) => ({ id: bundle.config.id, applied: false })),
                    };
                }

                if (!fs.existsSync(target.backupPath)) {
                    const backupDir = path.dirname(target.backupPath);
                    if (!fs.existsSync(backupDir)) {
                        await fs.promises.mkdir(backupDir, { recursive: true });
                    }
                    try {
                        await fs.promises.copyFile(target.fullPath, target.backupPath);
                    } catch (err: any) {
                        if (err?.code === "EACCES" && this.sessionsDir) {
                            const fallback = path.join(this.sessionsDir, `${path.basename(target.dirPath)}.${path.basename(target.fullPath)}.autonom.orig`);
                            if (target.backupPath !== fallback) {
                                target.backupPath = fallback;
                                await fs.promises.copyFile(target.fullPath, target.backupPath);
                            } else {
                                throw err;
                            }
                        } else {
                            throw err;
                        }
                    }
                    const backupBuffer = await fs.promises.readFile(target.backupPath);
                    if (computeSha256(backupBuffer) !== origSha) {
                        await fs.promises.rm(target.backupPath, { force: true });
                        throw new Error(`Backup verification failed: SHA-256 mismatch for ${target.fullPath}`);
                    }
                }

                await fs.promises.writeFile(target.fullPath, patched, "utf8");
                patchedAny = true;

                if (target.config.htmlRelPath) {
                    const htmlFull = path.join(this.appRoot || path.join(this.sessionsDir, "..", ".."), target.config.htmlRelPath);
                    const htmlBackup = `${htmlFull}.autonom.orig`;
                    if (fs.existsSync(htmlFull)) {
                        try {
                            let html = await fs.promises.readFile(htmlFull, "utf8");
                            let htmlChanged = false;
                            if (!html.includes("http://127.0.0.1:*")) {
                                html = html.replace("connect-src", "connect-src http://127.0.0.1:* http://localhost:*");
                                htmlChanged = true;
                            }
                            if (target.config.id === "sessions" && !html.includes("autonom.sessions.css")) {
                                html = html.replace("</head>", '<link rel="stylesheet" href="../autonom.sessions.css">\n</head>');
                                htmlChanged = true;
                            }
                            if (htmlChanged) {
                                if (!fs.existsSync(htmlBackup)) {
                                    await fs.promises.copyFile(htmlFull, htmlBackup);
                                }
                                await fs.promises.writeFile(htmlFull, html, "utf8");
                            }
                        } catch {
                            // Some vendor HTML directories are not user-writable; the bundle patch
                            // and companion deployment do not depend on the HTML changes.
                        }
                    }
                }
            }

            const patchedMap = new Map<string, Buffer>();
            for (const t of targetsToPatch) {
                try {
                    patchedMap.set(t.config.bundleRelPath, await fs.promises.readFile(t.fullPath));
                } catch {}
                if (t.config.htmlRelPath) {
                    const htmlFull = path.join(this.appRoot || path.join(this.sessionsDir, "..", ".."), t.config.htmlRelPath);
                    if (fs.existsSync(htmlFull)) {
                        try {
                            patchedMap.set(t.config.htmlRelPath, await fs.promises.readFile(htmlFull));
                        } catch {}
                    }
                }
            }
            this.syncProductChecksums(patchedMap);

            const bundleResults: { id: string; applied: boolean; alreadyPatched?: boolean | undefined; error?: string | undefined }[] = [];
            for (const target of available) {
                const isWritable = writableTargets.includes(target);
                const wasPatched = patchedBefore.get(target) ?? await this.isBundlePatched(target.fullPath, target.config);
                bundleResults.push({
                    id: target.config.id,
                    applied: isWritable && !wasPatched,
                    alreadyPatched: wasPatched,
                    error: isWritable ? undefined : `Write permission denied for ${target.fullPath}`,
                });
            }
            const unwritableError = unwritableTargets.length
                ? `Some Devin Desktop bundles are not writable: ${unwritableTargets.map((target) => target.fullPath).join(", ")}`
                : undefined;
            return {
                applied: unwritableTargets.length === 0 && patchedAny,
                alreadyPatched: !patchedAny,
                error: unwritableError,
                bundles: bundleResults,
            };
        } catch (err: any) {
            return {
                applied: false,
                error: err?.message || String(err),
                bundles: available.map((t) => ({ id: t.config.id, applied: false, error: err?.message || String(err) })),
            };
        }
    }

    public async applyPatch(): Promise<void> {
        const result = await this.ensurePatched();
        if (result.error) {
            throw new Error(result.error);
        }
    }

    public async restore(): Promise<RestoreResult> {
        try {
            const targets = this.getTargetBundles();
            for (const t of targets) {
                if (fs.existsSync(t.backupPath)) {
                    const backupBuffer = await fs.promises.readFile(t.backupPath);
                    const backupSha = computeSha256(backupBuffer);
                    await fs.promises.copyFile(t.backupPath, t.fullPath);
                    const restoredBuffer = await fs.promises.readFile(t.fullPath);
                    const restoredSha = computeSha256(restoredBuffer);
                    if (restoredSha !== backupSha) {
                        throw new Error(`SHA-256 rollback verification failed for ${t.fullPath}`);
                    }
                }

                if (t.config.htmlRelPath) {
                    const htmlFull = path.join(this.appRoot || path.join(this.sessionsDir, "..", ".."), t.config.htmlRelPath);
                    const htmlBackup = `${htmlFull}.autonom.orig`;
                    if (fs.existsSync(htmlBackup)) {
                        await fs.promises.copyFile(htmlBackup, htmlFull);
                    }
                }
            }

            if (fs.existsSync(this.htmlBackupPath)) {
                await fs.promises.copyFile(this.htmlBackupPath, this.htmlPath);
            }

            const destDirs = new Set<string>();
            if (this.sessionsDir) {
                destDirs.add(this.sessionsDir);
                destDirs.add(path.join(this.sessionsDir, "electron-browser"));
            }
            for (const t of targets) destDirs.add(t.dirPath);

            for (const dir of destDirs) {
                const companionBundle = path.join(dir, "autonom.bundle.js");
                const companionCss = path.join(dir, "autonom.sessions.css");
                const companionVersion = path.join(dir, "autonom.version.json");
                const bridgeDescriptor = path.join(dir, "autonom.bridge.json");
                if (fs.existsSync(companionBundle)) {
                    await fs.promises.rm(companionBundle, { force: true });
                }
                if (fs.existsSync(companionCss)) {
                    await fs.promises.rm(companionCss, { force: true });
                }
                if (fs.existsSync(companionVersion)) {
                    await fs.promises.rm(companionVersion, { force: true });
                }
                if (fs.existsSync(bridgeDescriptor)) {
                    await fs.promises.rm(bridgeDescriptor, { force: true });
                }
            }

            const relPathsToRestore: string[] = [];
            for (const t of targets) {
                relPathsToRestore.push(t.config.bundleRelPath);
                if (t.config.htmlRelPath) {
                    relPathsToRestore.push(t.config.htmlRelPath);
                }
            }
            this.restoreProductChecksums(relPathsToRestore);

            return {
                restored: true,
                bundles: targets.map((t) => ({ id: t.config.id, restored: true })),
            };
        } catch (err: any) {
            return {
                restored: false,
                error: err?.message || String(err),
                bundles: this.getTargetBundles().map((t) => ({ id: t.config.id, restored: false, error: err?.message || String(err) })),
            };
        }
    }

    public async restoreOriginal(): Promise<RestoreResult> {
        return this.restore();
    }

    public async deployCompanion(): Promise<void> {
        const contextBundle = this.context?.asAbsolutePath?.("dist/commandCenter/autonom.bundle.js") || "";
        const contextCss = this.context?.asAbsolutePath?.("dist/commandCenter/autonom.sessions.css") || "";
        const bundlePaths = this.context ? [contextBundle] : [
            path.resolve(__dirname, "commandCenter", "autonom.bundle.js"),
            path.resolve(__dirname, "..", "dist", "commandCenter", "autonom.bundle.js"),
            path.resolve(process.cwd(), "extension", "dist", "commandCenter", "autonom.bundle.js"),
            path.resolve(process.cwd(), "dist", "commandCenter", "autonom.bundle.js"),
        ];
        const cssPaths = this.context ? [contextCss] : [
            path.resolve(__dirname, "commandCenter", "autonom.sessions.css"),
            path.resolve(__dirname, "..", "dist", "commandCenter", "autonom.sessions.css"),
            path.resolve(process.cwd(), "extension", "dist", "commandCenter", "autonom.sessions.css"),
            path.resolve(process.cwd(), "dist", "commandCenter", "autonom.sessions.css"),
        ];
        const srcBundle = bundlePaths.find((candidate) => candidate && fs.existsSync(candidate));
        const srcCss = cssPaths.find((candidate) => candidate && fs.existsSync(candidate));
        if (!srcBundle || !srcCss) {
            if (this.context)
                throw new Error("Build the Autonom companion bundle and stylesheet before deployment.");
            return;
        }

        const destDirs = new Set([this.sessionsDir, path.join(this.sessionsDir, "electron-browser")]);
        const version = Buffer.from(JSON.stringify({ version: computeSha256(await fs.promises.readFile(srcBundle)).slice(0, 16) }));
        for (const dir of destDirs) {
            await fs.promises.mkdir(dir, { recursive: true });
            const bundlePath = path.join(dir, "autonom.bundle.js");
            const cssPath = path.join(dir, "autonom.sessions.css");
            const versionPath = path.join(dir, "autonom.version.json");
            await fs.promises.copyFile(srcBundle, bundlePath);
            await fs.promises.copyFile(srcCss, cssPath);
            await fs.promises.writeFile(versionPath, version);
            if (computeSha256(await fs.promises.readFile(bundlePath)) !== computeSha256(await fs.promises.readFile(srcBundle))
                || computeSha256(await fs.promises.readFile(cssPath)) !== computeSha256(await fs.promises.readFile(srcCss)))
                throw new Error(`Companion deployment verification failed for ${dir}`);
        }
    }
}
