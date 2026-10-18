import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../../assets/icons/autonom.svg";

import {
    Cloud,
    Cog,
    Pencil,
    Plus,
    Search,
    ShieldCheck,
    ShieldLock,
    Sliders,
    Timer,
    X,
    createElement,
    type IconNode,
} from "lucide";

const lucideIcons: Record<string, IconNode> = {
    timer: Timer,
    "shield-lock": ShieldLock,
    "shield-check": ShieldLock,
    shieldCheck: ShieldCheck,
    cog: Cog,
    settings: Cog,
    sliders: Sliders,
    plus: Plus,
    search: Search,
    x: X,
    close: X,
    cloud: Cloud,
    pencil: Pencil,
};

const customMarkups: Record<string, string> = {
    autonom: autonomLineMarkup,
    "autonom-fill": autonomFillMarkup,
};

function parseSvg(markup: string): SVGSVGElement
{
    const ret = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const svgOpenMatch = /<svg\b([^>]*)>/i.exec(markup);
    if (svgOpenMatch)
    {
        const attrRegex = /([a-z0-9-]+)=["']([^"']*)["']/gi;
        let attrMatch: RegExpExecArray | null;
        while ((attrMatch = attrRegex.exec(svgOpenMatch[1]!)) !== null)
        {
            const name = attrMatch[1];
            const value = attrMatch[2];
            if (name && value !== undefined && name !== "xmlns" && name !== "width" && name !== "height")
                ret.setAttribute(name, value);
        }
    }
    ret.setAttribute("aria-hidden", "true");
    if (!ret.getAttribute("viewBox"))
        ret.setAttribute("viewBox", "0 0 24 24");

    const tagRegex = /<([a-z0-9]+)\b([^>]*)>/gi;
    let tagMatch: RegExpExecArray | null;
    while ((tagMatch = tagRegex.exec(markup)) !== null)
    {
        const tagName = tagMatch[1]!.toLowerCase();
        if (tagName === "svg" || tagName === "!--")
            continue;

        const child = document.createElementNS("http://www.w3.org/2000/svg", tagName);
        const attrRegex = /([a-z0-9-]+)=["']([^"']*)["']/gi;
        let attrMatch: RegExpExecArray | null;
        while ((attrMatch = attrRegex.exec(tagMatch[2]!)) !== null)
        {
            const name = attrMatch[1];
            const value = attrMatch[2];
            if (name && value !== undefined)
                child.setAttribute(name, value);
        }

        ret.appendChild(child);
    }

    return ret;
}

export function createIcon(name: string | undefined, fallback?: string): SVGSVGElement | undefined
{
    const resolvedName = (name && (lucideIcons[name] || customMarkups[name])) ? name
        : (fallback && (lucideIcons[fallback] || customMarkups[fallback])) ? fallback
        : undefined;

    if (!resolvedName)
        return undefined;

    const lucideNode = lucideIcons[resolvedName];
    if (lucideNode)
        return createElement(lucideNode, { "aria-hidden": "true" }) as SVGSVGElement;

    const markup = customMarkups[resolvedName];
    if (markup)
        return parseSvg(markup);

    return undefined;
}

export function sectionIcon(name: string | undefined, fallback = "plus"): SVGSVGElement
{
    return createIcon(name, fallback)!;
}
