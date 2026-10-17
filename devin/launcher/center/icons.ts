import closeMarkup from "../../../assets/icons/close.svg";
import plusMarkup from "../../../assets/icons/plus.svg";
import searchMarkup from "../../../assets/icons/search.svg";
import slidersMarkup from "../../../assets/icons/sliders.svg";

const markups: Record<string, string> = {
    search: searchMarkup,
    plus: plusMarkup,
    sliders: slidersMarkup,
    close: closeMarkup,
};

export function sectionIcon(name: string | undefined, fallback = "plus"): SVGSVGElement
{
    const markup = markups[name ?? fallback] ?? markups[fallback]!;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", /viewBox="([^"]+)"/.exec(markup)?.[1] ?? "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill", "currentColor");
    path.setAttribute("fill-rule", "evenodd");
    path.setAttribute("d", /[\s]d="([^"]+)"/.exec(markup)?.[1] ?? "");
    svg.appendChild(path);
    return svg;
}
