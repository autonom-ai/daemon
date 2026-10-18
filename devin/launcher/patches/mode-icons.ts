import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../../assets/icons/autonom.svg";


import { Cloud, Pencil, type IconNode } from "lucide";

type Mode = "autonom" | "devin-cloud" | "editor";

interface ShellIcon
{
    viewBox: string;
    line: string;
    fill: string;
    stroked: boolean;
}

function iconSet(lineMarkup: string, fillMarkup: string): ShellIcon
{
    const extractPaths = (markup: string) =>
        [...markup.matchAll(/[\s]d="([^"]+)"/g)].map((match) => match[1]).join(" ");

    return {
        viewBox: /viewBox="([^"]+)"/.exec(lineMarkup)?.[1] ?? "0 0 24 24",
        line: extractPaths(lineMarkup),
        fill: extractPaths(fillMarkup),
        stroked: lineMarkup.includes('stroke="currentColor"'),
    };
}

function iconSetFromNode(lineNode: IconNode, fillNode?: IconNode): ShellIcon
{
    const extract = (node: IconNode) =>
        node.map(([, attrs]) => attrs.d).filter(Boolean).join(" ");

    return {
        viewBox: "0 0 24 24",
        line: extract(lineNode),
        fill: fillNode ? extract(fillNode) : extract(lineNode),
        stroked: true,
    };
}

export const shellIcons: Record<Mode, ShellIcon> = {
    autonom: iconSet(autonomLineMarkup, autonomFillMarkup),
    "devin-cloud": iconSetFromNode(Cloud),
    editor: iconSetFromNode(Pencil, Pencil.slice(0, 1)),
};
