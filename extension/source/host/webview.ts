import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as vscode from "vscode";

export function webviewHtml(webview: vscode.Webview, extension: vscode.Uri, sidebar: boolean): string
{
    const nonce = randomBytes(24).toString("base64");
    const media = vscode.Uri.joinPath(extension, "media");
    const distribution = vscode.Uri.joinPath(extension, "dist");
    webview.options = { enableScripts: true, localResourceRoots: [media, distribution] };
    return readFileSync(join(extension.fsPath, "media", "webview.html"), "utf8")
        .replaceAll("{{CSP_SOURCE}}", webview.cspSource)
        .replaceAll("{{NONCE}}", nonce)
        .replaceAll("{{CSS_URI}}", webview.asWebviewUri(vscode.Uri.joinPath(media, "webview.css")).toString())
        .replaceAll("{{JS_URI}}", webview.asWebviewUri(vscode.Uri.joinPath(distribution, "webview.js")).toString())
        .replaceAll("{{ICONS_URI}}", webview.asWebviewUri(vscode.Uri.joinPath(distribution, "icons.svg")).toString())
        .replaceAll("{{VIEW}}", sidebar ? "sidebar" : "workspace");
}
