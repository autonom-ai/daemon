import { watch } from "node:fs";
import { extname } from "node:path";

export function watchContent(
    directory: string, changed: () => void, failed: (error: Error) => void,
): { close(): void }
{
    let timer: ReturnType<typeof setTimeout> | undefined;
    const watcher = watch(directory, { recursive: true }, (_event, filename) =>
    {
        if (filename && ![".yml", ".html", ".js", ".css"].includes(extname(String(filename))))
            return;

        clearTimeout(timer);
        timer = setTimeout(changed, 75);
    });
    watcher.on("error", failed);
    return {
        close(): void
        {
            clearTimeout(timer);
            watcher.close();
        },
    };
}
