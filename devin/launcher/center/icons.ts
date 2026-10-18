import closeMarkup from "../../../assets/icons/close.svg";
import cogMarkup from "../../../assets/icons/cog.svg";
import plusMarkup from "../../../assets/icons/plus.svg";
import searchMarkup from "../../../assets/icons/search.svg";
import shieldLockMarkup from "../../../assets/icons/shield-lock.svg";
import slidersMarkup from "../../../assets/icons/sliders.svg";
import timerMarkup from "../../../assets/icons/timer.svg";

const markups: Record<string, string> = {
    search: searchMarkup,
    plus: plusMarkup,
    sliders: slidersMarkup,
    close: closeMarkup,
    timer: timerMarkup,
    "shield-lock": shieldLockMarkup,
    "shield-check": shieldLockMarkup,
    cog: cogMarkup,
    settings: cogMarkup,
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
    const markup = (name && markups[name]) || (fallback && markups[fallback]);
    if (!markup)
        return undefined;

    return parseSvg(markup);
}

export function sectionIcon(name: string | undefined, fallback = "plus"): SVGSVGElement
{
    return createIcon(name, fallback)!;
}
