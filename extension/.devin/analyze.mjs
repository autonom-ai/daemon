import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { transform } from "esbuild";

const [kind = "workbench", ...patterns] = process.argv.slice(2);
const paths = {
    workbench: "/usr/share/devin-desktop/resources/app/out/vs/workbench/windsurf-chat-client/index.js",
    sessions: "/usr/share/devin-desktop/resources/app/out/vs/sessions/sessions.desktop.main.js",
    host: "/usr/share/devin-desktop/resources/app/out/vs/workbench/workbench.desktop.main.js",
};
const source = await readFile(paths[kind], "utf8");
await transform(source, { loader: "js", minify: false });
console.log(JSON.stringify({ kind, bytes: source.length, sha256: createHash("sha256").update(source).digest("hex") }));
for (const pattern of patterns) {
    let offset = 0;
    let count = 0;
    while ((offset = source.indexOf(pattern, offset)) >= 0 && count++ < 8) {
        console.log(JSON.stringify({ pattern, offset }));
        console.log(source.slice(Math.max(0, offset - 500), offset + 4500).match(/.{1,120}/g).join("\n"));
        offset += pattern.length;
    }
}
