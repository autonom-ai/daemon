#!/usr/bin/env node
// Print the rendered DOM subtree under a selector as an indented tree with
// layout/hidden state, to find duplicate mounts and effective visibility.
//
//   node scripts/dom-tree.mjs "[data-slot='sidebar-group']"
//   node scripts/dom-tree.mjs ".command-center-sidebar-root" --depth 3
//   node scripts/dom-tree.mjs "body" --depth 2 --all

import { CdpSession } from "./cdp.mjs";

const args = process.argv.slice(2);
const selector = args[0] || "body";
const depthIndex = args.indexOf("--depth");
const maxDepth = depthIndex >= 0 ? Number(args[depthIndex + 1]) : 4;
const includeAll = args.includes("--all");

const match = { urlIncludes: process.env.CC_TARGET || "workbench.html" };
const session = await CdpSession.open(match).catch((error) => {
    console.error(error.message);
    process.exit(1);
});

try {
    const tree = await session.evaluateFunction(
        (sel, limit, all) => {
            const roots = [...document.querySelectorAll(sel)];
            if (roots.length === 0) return `no elements for ${sel}`;
            const lines = [];
            const walk = (element, depth, prefix) => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                const classes = element.className?.toString?.().replace(/\s+/g, " ").trim() || "";
                const attrs = [...element.attributes]
                    .filter((attr) => !["class", "style"].includes(attr.name))
                    .map((attr) => `${attr.name}="${attr.value.slice(0, 40)}"`)
                    .join(" ");
                const label = [
                    `<${element.tagName.toLowerCase()}`,
                    classes ? `.${classes.split(" ").join(".")}` : "",
                    attrs ? ` ${attrs}` : "",
                    `> [${Math.round(rect.x)},${Math.round(rect.y)} ${Math.round(rect.width)}x${Math.round(rect.height)}]`,
                    `display=${style.display}`,
                    element.hidden ? "hidden" : "",
                    style.display === "none" || !element.checkVisibility() ? "invisible" : "",
                ].join("");
                lines.push(`${prefix}${label}`);
                if (depth >= limit) return;
                for (const child of element.children) {
                    if (!all && child.getBoundingClientRect().width === 0 && child.getBoundingClientRect().height === 0 && depth > 0) continue;
                    walk(child, depth + 1, `${prefix}  `);
                }
            };
            for (const root of roots) walk(root, 0, "");
            return lines.join("\n");
        },
        selector,
        maxDepth,
        includeAll,
    );
    console.log(tree);
} catch (error) {
    console.error(error.message);
    process.exit(1);
} finally {
    session.close();
}
