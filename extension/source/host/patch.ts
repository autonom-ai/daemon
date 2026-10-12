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
};

export const SESSIONS_BUNDLE_CONFIG: BundleConfig = {
    id: "sessions",
    displayName: "Standalone Sessions Window",
    bundleRelPath: path.join("out", "vs", "sessions", "sessions.desktop.main.js"),
    jsxVar: "_",
    hook1Slot: '_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session"',
    hook2Slot: 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"',
    hook3Slot: 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]',
    htmlRelPath: path.join("out", "vs", "sessions", "electron-browser", "sessions.html"),
};

export const TARGET_BUNDLES: BundleConfig[] = [WORKBENCH_BUNDLE_CONFIG, SESSIONS_BUNDLE_CONFIG];

export function computeSha256(data: string | Buffer): string {
    return createHash("sha256").update(data).digest("hex");
}

/**
 * Self-contained inline micro-hook bootstrap.
 * Defines globalThis.__autonom synchronously with safe fallbacks and initiates a
 * non-blocking dynamic import of ./autonom.bundle.js without static import hazards.
 * Strictly respects Trusted Types: zero raw innerHTML string assignments.
 */
export const BOOTSTRAP_HEADER = `${MARKER_V1}/* Autonom Command Center Self-Contained Micro-Hook */
(function(){
if(globalThis.__autonom)return;
var m={};
function g(k,d){try{return(typeof localStorage!=="undefined"&&localStorage.getItem(k))||m[k]||d;}catch{return m[k]||d;}}
function s(k,v){try{if(typeof localStorage!=="undefined")localStorage.setItem(k,v);}catch{} m[k]=v;}

var l=new Set();
var a={
get provider(){return g("autonom.provider","autonom");},
set provider(v){
s("autonom.provider",v);
var on=v!=="devin-cloud";
if(typeof document!=="undefined"){
document.querySelectorAll("[data-provider='autonom']").forEach(function(e){e.classList.toggle("active",on);e.setAttribute("data-active",String(on));});
document.querySelectorAll("[data-provider='devin-cloud']").forEach(function(e){e.classList.toggle("active",!on);e.setAttribute("data-active",String(!on));});
document.querySelectorAll("[data-autonom-tier],.command-center-sidebar-root").forEach(function(e){e.hidden=!on;});
document.querySelectorAll("[data-slot='sidebar-group']:not([data-autonom-tier]),.command-center-cloud").forEach(function(e){e.hidden=on;});
}
for(var c of l){try{c(v);}catch{}}
},
setProvider:function(v){this.provider=v;},
subscribe:function(c){l.add(c);return function(){l.delete(c);};},
isAutonomActive:function(){return this.provider!=="devin-cloud";},
wrapNewSession:function(jsxRuntime){
return function(n,p,k){
var r=jsxRuntime||globalThis._||globalThis.tX;
var on=a.isAutonomActive();
var t=r.jsx("li",{"data-slot":"sidebar-menu-item",className:"group/menu-item relative isolate mb-2 mt-1",key:"__autonom_toggle_item",children:r.jsxs("div",{className:"switch-container group/switch relative flex w-full p-0.5 rounded-[7px] bg-tint-secondary items-center h-[28px] box-border mb-1",style:{backgroundColor:"rgb(var(--tint-secondary,255 255 255 / 0.06))",border:"1px solid rgb(var(--border-secondary,255 255 255 / 0.08))"},children:[r.jsx("button",{type:"button","data-provider":"autonom","data-active":String(on),className:"switch-segment "+(on?"active":"")+" flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all",onClick:function(){a.setProvider("autonom");},children:"Autonom"}),r.jsx("button",{type:"button","data-provider":"devin-cloud","data-active":String(!on),className:"switch-segment "+(!on?"active":"")+" flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all",onClick:function(){a.setProvider("devin-cloud");},children:"Devin Cloud"})]})});
var o=r.jsx(n,p,k);
return r.jsxs(r.Fragment||"div",{key:"__autonom_new_session_slot",children:[t,o]});
};
},
renderSidebar:function(){return null;},
renderCenter:function(){return null;}
};
globalThis.__autonom=a;
if(typeof document!=="undefined"&&!document.getElementById("autonom-companion-style")){
try{
var lk=document.createElement("link");
lk.id="autonom-companion-style";
lk.rel="stylesheet";
lk.href="./autonom.sessions.css";
document.head.appendChild(lk);
}catch(e){}
}
try{
import("./autonom.bundle.js").then(function(m){if(m&&typeof m.init==="function"){m.init(globalThis);a.provider=a.provider;}}).catch(function(){});
}catch(e){}
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
            this.appRoot = detectedRoot || appRootOrContext.extensionUri?.fsPath || "";
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

    public getTargetBundles(): { config: BundleConfig; fullPath: string; backupPath: string; dirPath: string }[] {
        const wbPath = this.appRoot
            ? path.join(this.appRoot, WORKBENCH_BUNDLE_CONFIG.bundleRelPath)
            : path.join(this.sessionsDir, "..", "workbench", "windsurf-chat-client", "index.js");
        const sessPath = this.mainJsPath;

        return [
            {
                config: WORKBENCH_BUNDLE_CONFIG,
                fullPath: wbPath,
                backupPath: `${wbPath}.autonom.orig`,
                dirPath: path.dirname(wbPath),
            },
            {
                config: SESSIONS_BUNDLE_CONFIG,
                fullPath: sessPath,
                backupPath: this.backupPath || `${sessPath}.autonom.orig`,
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
            const patched = await this.isBundlePatched(t.fullPath);

            if (!patched) allPatched = false;
            if (!writable) {
                allWritable = false;
                if (!firstUnwritableError) {
                    firstUnwritableError = `Write permission denied for ${t.fullPath}. Please grant write permission: sudo chown -R $USER ${t.dirPath}`;
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

    private async isBundlePatched(filePath: string): Promise<boolean> {
        if (!fs.existsSync(filePath)) {
            return false;
        }
        try {
            const content = await fs.promises.readFile(filePath, "utf8");
            return (
                content.includes(MARKER_V1) ||
                content.includes(MARKER_P1) ||
                content.includes(MARKER_TOGGLE) ||
                content.includes("__autonom_provider_toggle")
            );
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
        const results = await Promise.all(available.map((t) => this.isBundlePatched(t.fullPath)));
        return results.every(Boolean);
    }

    public async ensurePatched(): Promise<PatchResult> {
        const targets = this.getTargetBundles();
        const available = targets.filter((t) => fs.existsSync(t.fullPath));

        if (available.length === 0) {
            return { applied: false, error: "Devin Desktop bundles not found in environment." };
        }

        // Writability check: probe write permissions without throwing unhandled exceptions
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
                error: `Write permission denied for ${unwritableTargets.map((t) => t.fullPath).join(", ")}. Please grant write permission: sudo chown -R $USER ${unwritableTargets.map((t) => t.dirPath).join(" ")}`,
            };
        }

        const targetsToPatch = writableTargets;

        // Check already patched status
        const patchStatuses = await Promise.all(targetsToPatch.map((t) => this.isBundlePatched(t.fullPath)));
        if (patchStatuses.every(Boolean)) {
            await this.deployCompanion();
            return { applied: false, alreadyPatched: true };
        }

        // Validate hook slots on all unpatched bundles before making any changes
        for (let i = 0; i < targetsToPatch.length; i++) {
            if (!patchStatuses[i]) {
                const t = targetsToPatch[i]!;
                let content: string;
                try {
                    content = await fs.promises.readFile(t.fullPath, "utf8");
                } catch (err: any) {
                    return { applied: false, error: `Failed to read target bundle ${t.fullPath}: ${err?.message || err}` };
                }
                if (!content.includes(t.config.hook1Slot)) {
                    return { applied: false, error: `Vendor hook slot not found in ${path.basename(t.fullPath)}` };
                }
            }
        }

        try {
            // Deploy companion assets before modifying bundles
            await this.deployCompanion();

            // Apply patch to unpatched bundles
            for (let i = 0; i < targetsToPatch.length; i++) {
                if (patchStatuses[i]) {
                    continue;
                }
                const t = targetsToPatch[i]!;
                const content = await fs.promises.readFile(t.fullPath, "utf8");
                const origSha = computeSha256(content);

                // 1. Create atomic permanent backup with SHA-256 verification
                if (!fs.existsSync(t.backupPath)) {
                    await fs.promises.copyFile(t.fullPath, t.backupPath);
                    const backupBuffer = await fs.promises.readFile(t.backupPath);
                    const backupSha = computeSha256(backupBuffer);
                    if (backupSha !== origSha) {
                        await fs.promises.rm(t.backupPath, { force: true });
                        throw new Error(`Backup verification failed: SHA-256 mismatch for ${t.fullPath}`);
                    }
                }

                // 2. Perform surgical replacements
                const hook1Target = t.config.hook1Slot;
                const slotSuffix = hook1Target.slice(hook1Target.indexOf("(") + 1);
                const hook1Replacement = `${MARKER_P1}${MARKER_TOGGLE}(globalThis.__autonom?.wrapNewSession?.(${t.config.jsxVar})??${t.config.jsxVar}.jsx))(${slotSuffix}`;
                let patched = content.replace(hook1Target, hook1Replacement);

                // Hook 2: Spaces rail navigation (if configured and present)
                if (t.config.hook2Slot && patched.includes(t.config.hook2Slot)) {
                    if (t.config.id === "workbench") {
                        const wbH2Target = 'children:[tg,(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces"';
                        const wbH2Replacement = `${MARKER_P2}children:[tg,globalThis.__autonom?.isAutonomActive?.()?globalThis.__autonom?.renderSidebar?.(tX):(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces"`;
                        if (patched.includes(wbH2Target)) {
                            patched = patched.replace(wbH2Target, wbH2Replacement);
                        }
                    } else {
                        const sessH2Target = 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"';
                        const sessH2Replacement = `${MARKER_P2}children:[jY,globalThis.__autonom?.isAutonomActive?.()?globalThis.__autonom?.renderSidebar?.(_):(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"`;
                        if (patched.includes(sessH2Target)) {
                            patched = patched.replace(sessH2Target, sessH2Replacement);
                        }
                    }
                }

                // Hook 3: Center viewport (if configured and present)
                if (t.config.hook3Slot && patched.includes(t.config.hook3Slot)) {
                    if (t.config.id === "workbench") {
                        const wbH3Target = 'children:[(0,tX.jsx)(iqs,{}),(0,tX.jsx)(ewt,{})]';
                        const wbH3Replacement = `${MARKER_P3}children:[(0,tX.jsx)(iqs,{}),(globalThis.__autonom?.isAutonomActive?.()&&globalThis.__autonom?.renderCenter?.(tX))||(0,tX.jsx)(ewt,{})]`;
                        if (patched.includes(wbH3Target)) {
                            patched = patched.replace(wbH3Target, wbH3Replacement);
                        }
                    } else {
                        const sessH3Target = 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]';
                        const sessH3Replacement = `${MARKER_P3}children:[(0,_.jsx)(vsu,{}),(globalThis.__autonom?.isAutonomActive?.()&&globalThis.__autonom?.renderCenter?.(_))||(0,_.jsx)(WTr,{})]`;
                        if (patched.includes(sessH3Target)) {
                            patched = patched.replace(sessH3Target, sessH3Replacement);
                        }
                    }
                }

                // Prepend self-contained bootstrap header with safe dynamic loader
                patched = BOOTSTRAP_HEADER + patched;
                await fs.promises.writeFile(t.fullPath, patched, "utf8");

                // Patch companion HTML if configured and present
                if (t.config.htmlRelPath) {
                    const htmlFull = path.join(this.appRoot || path.join(this.sessionsDir, "..", ".."), t.config.htmlRelPath);
                    const htmlBackup = `${htmlFull}.autonom.orig`;
                    if (fs.existsSync(htmlFull)) {
                        if (!fs.existsSync(htmlBackup)) {
                            await fs.promises.copyFile(htmlFull, htmlBackup);
                        }
                        let html = await fs.promises.readFile(htmlFull, "utf8");
                        let htmlChanged = false;
                        if (!html.includes("http://127.0.0.1:*")) {
                            html = html.replace("connect-src", "connect-src http://127.0.0.1:* http://localhost:*");
                            htmlChanged = true;
                        }
                        if (!html.includes("autonom.sessions.css")) {
                            html = html.replace("</head>", '<link rel="stylesheet" href="../autonom.sessions.css">\n</head>');
                            htmlChanged = true;
                        }
                        if (htmlChanged) {
                            await fs.promises.writeFile(htmlFull, html, "utf8");
                        }
                    }
                }
            }

            return { applied: true };
        } catch (err: any) {
            return { applied: false, error: err?.message || String(err) };
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
            if (this.sessionsDir) destDirs.add(this.sessionsDir);
            for (const t of targets) destDirs.add(t.dirPath);

            for (const dir of destDirs) {
                const companionBundle = path.join(dir, "autonom.bundle.js");
                const companionCss = path.join(dir, "autonom.sessions.css");
                if (fs.existsSync(companionBundle)) {
                    await fs.promises.rm(companionBundle, { force: true });
                }
                if (fs.existsSync(companionCss)) {
                    await fs.promises.rm(companionCss, { force: true });
                }
            }

            return { restored: true };
        } catch (err: any) {
            return { restored: false, error: err?.message || String(err) };
        }
    }

    public async restoreOriginal(): Promise<RestoreResult> {
        return this.restore();
    }

    public async deployCompanion(): Promise<void> {
        let srcBundle = "";
        let srcCss = "";
        if (this.context?.asAbsolutePath) {
            srcBundle = this.context.asAbsolutePath("dist/commandCenter/autonom.bundle.js");
            srcCss = this.context.asAbsolutePath("dist/commandCenter/autonom.sessions.css");
        }
        if (!srcBundle || !fs.existsSync(srcBundle)) {
            const fallbackBundle = path.resolve(__dirname, "..", "commandCenter", "autonom.bundle.js");
            const fallbackCss = path.resolve(__dirname, "..", "commandCenter", "autonom.sessions.css");
            if (fs.existsSync(fallbackBundle)) {
                srcBundle = fallbackBundle;
            }
            if (fs.existsSync(fallbackCss)) {
                srcCss = fallbackCss;
            }
        }

        const destDirs = new Set<string>();
        if (this.sessionsDir) {
            destDirs.add(this.sessionsDir);
            destDirs.add(path.join(this.sessionsDir, "electron-browser"));
        }
        for (const t of this.getTargetBundles()) {
            if (fs.existsSync(t.fullPath) || fs.existsSync(t.dirPath)) {
                destDirs.add(t.dirPath);
            }
        }

        for (const dir of destDirs) {
            try {
                if (srcBundle && fs.existsSync(srcBundle)) {
                    await fs.promises.copyFile(srcBundle, path.join(dir, "autonom.bundle.js"));
                }
                if (srcCss && fs.existsSync(srcCss)) {
                    await fs.promises.copyFile(srcCss, path.join(dir, "autonom.sessions.css"));
                }
            } catch {
                // Ignore deployment if source assets not compiled yet or permissions fail
            }
        }
    }
}
