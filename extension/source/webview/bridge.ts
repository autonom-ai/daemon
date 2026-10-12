import type { HostAction } from "../protocol";

export type Bridge = {
    postMessage: (message: HostAction) => void;
    getState: () => unknown;
    setState: (value: unknown) => void;
};

declare function acquireVsCodeApi(): Bridge;

export const bridge = acquireVsCodeApi();

export function field(form: HTMLFormElement, name: string): string
{
    return String(new FormData(form).get(name) ?? "");
}

export function toast(text: string, error = false): void
{
    const target = document.getElementById("toast");
    if (target === null)
        return;
    target.textContent = text;
    target.classList.toggle("error", error);
    target.hidden = false;
    window.setTimeout(() => { target.hidden = true; }, 6000);
}
