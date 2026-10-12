import { record, text } from "../protocol";
import { generateIdenticonSvg, hashProfileName, identicon } from "./identicon";

export { generateIdenticonSvg, hashProfileName, identicon };

export function escape(value: unknown): string
{
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    })[character] ?? character);
}

export function icon(name: string, className = ""): string
{
    const source = document.querySelector<HTMLMetaElement>('meta[name="autonom-icons"]')?.content ?? "";
    return `<svg class="icon ${escape(className)}" aria-hidden="true" viewBox="0 0 16 16"><use href="${escape(source)}#${escape(name)}"></use></svg>`;
}

export function iconButton(action: string, name: string, label: string, extra = ""): string
{
    return `<button class="icon-button" type="button" data-action="${escape(action)}" title="${escape(label)}" aria-label="${escape(label)}" ${extra}>${icon(name)}</button>`;
}

export function avatar(name: string, size = ""): string
{
    const lower = (name || "").toLowerCase().trim();
    if (lower === "you" || lower === "human")
    {
        return `<span class="avatar ${escape(size)}" data-human="true" aria-hidden="true">${icon("person")}</span>`;
    }
    const px = size === "small" ? 20 : size === "large" ? 32 : 22;
    return identicon(name, px, escape(size));
}

export function statusLabel(status: string): string
{
    return ({ online: "Working", starting: "Starting", stopping: "Stopping", loaded: "Open elsewhere",
        failed: "Failed", offline: "Idle", running: "Working", succeeded: "Complete", stopped: "Stopped",
        interrupted: "Interrupted" })[status] ?? status;
}

export function date(timestamp: unknown): Date | undefined
{
    if (typeof timestamp === "number")
    {
        const millis = timestamp > 60000000000000 ? timestamp - 62135596800000
            : timestamp < 100000000000 ? timestamp * 1000 : timestamp;
        const ret = new Date(millis);
        return Number.isNaN(ret.getTime()) ? undefined : ret;
    }
    if (typeof timestamp === "string")
    {
        const ret = new Date(timestamp);
        return Number.isNaN(ret.getTime()) ? undefined : ret;
    }
    return undefined;
}

export function timeLabel(timestamp: unknown): string
{
    return date(timestamp)?.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) ?? "";
}

export function relativeTime(timestamp: unknown): string
{
    const value = date(timestamp);
    if (value === undefined)
        return "";
    const seconds = Math.max(0, Math.floor((Date.now() - value.getTime()) / 1000));
    if (seconds < 60)
        return "now";
    if (seconds < 3600)
        return `${Math.floor(seconds / 60)}m`;
    if (seconds < 86400)
        return `${Math.floor(seconds / 3600)}h`;
    return `${Math.floor(seconds / 86400)}d`;
}

export function contentText(value: unknown): string
{
    if (typeof value === "string")
        return value;
    if (!Array.isArray(value))
        return text(record(value)?.text);
    return value.map((item) => text(record(item)?.text)).filter(Boolean).join("\n");
}

export function modelOptions(models: { id: string; label: string; family: string; cost?: string }[], selected: string): string
{
    const target = selected || "swe-2-medium";
    const values = models.length ? models : [{ id: "swe-2-medium", label: "SWE-2 Medium", family: "SWE-2", cost: "Free" }];
    const ret: string[] = [];
    if (target && !values.some((model) => model.id === target))
        ret.push(`<option value="${escape(target)}" selected>${escape(target)}</option>`);
    let family = "";
    for (const model of values)
    {
        if (model.family !== family)
        {
            if (family)
                ret.push("</optgroup>");
            family = model.family;
            ret.push(`<optgroup label="${escape(family)}">`);
        }
        ret.push(`<option value="${escape(model.id)}" ${model.id === target ? "selected" : ""}>${escape(model.label)}</option>`);
    }
    if (family)
        ret.push("</optgroup>");
    return ret.join("");
}

export function modeOptions(selected: string): string
{
    const modes = { auto: "Ask permissions", "accept-edits": "Accept edits", smart: "Smart", bypass: "Bypass permissions" };
    return Object.entries(modes).map(([value, label]) => `<option value="${value}" ${value === selected ? "selected" : ""}>${label}</option>`).join("");
}
