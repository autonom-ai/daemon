export type ServiceCapture = {
    name: string;
    assignments: string;
};

export function probe(): any
{
    for (const element of document.querySelectorAll("[data-slot=sidebar-menu], [data-slot=sidebar]"))
    {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (element as any)[key] : null;
        for (let index = 0; fiber && index < 128; index++, fiber = fiber.return)
        {
            const props = fiber.memoizedProps;
            if (typeof props?.getDesktopNavSurfacesSnapshot === "function"
                && typeof props?.getActiveDesktopNavSurfaceSnapshot === "function" && props.vscodeAPI?.executeCommand)
                return { props, api: props.vscodeAPI };
        }
    }
    return null;
}

export const SERVICE_CAPTURE: ServiceCapture[] = [
    {
        name: "getDesktopNavSurfacesSnapshot",
        assignments: "globalThis.__autonomServices={manifest:this._manifestService,controller:yAe.prototype};true",
    },
    {
        name: "getActiveDesktopNavSurfaceSnapshot",
        assignments: "globalThis.__autonomServices.groups=o;globalThis.__autonomServices.windowId=e.vscodeWindowId;"
            + "globalThis.__autonomServices.api=globalThis.__autonomAttachProbe.api;true",
    },
];
