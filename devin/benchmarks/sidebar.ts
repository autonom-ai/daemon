import { connectWindow } from "../tests/cdp";

export type Sample = {
    update: number[];
    heartbeat: number[];
    nodes: number;
    candidates: number;
    visibleMasks: number;
    metricsBefore: unknown;
    metricsAfter: unknown;
};

export async function benchmark(targetId: string): Promise<Sample>
{
    const window = await connectWindow(targetId);
    try
    {
        return await window.session.evaluate(`(() => {
            const shell = globalThis.__autonomShell;
            if (!shell) throw new Error("The production shell is not attached");
            const css = [...document.querySelectorAll("style")].find(s => s.textContent.includes("[data-autonom-mode-switch]"))?.textContent;
            if (!css) throw new Error("The production shell stylesheet is missing");
            const selector = "svg, img, [style*='mask-image'], [role='img'], .codicon-devin-logo, div:not(:has(*)), span:not(:has(*))";
            for (let i=0;i<3;i++) { shell.update(css); shell.heartbeat(); }
            const metricsBefore = shell.performance?.() ?? null;
            const update=[], heartbeat=[];
            for (let i=0;i<30;i++) {
                let start=performance.now(); shell.update(css); update.push(performance.now()-start);
                start=performance.now(); shell.heartbeat(); heartbeat.push(performance.now()-start);
            }
            return {
                update, heartbeat, metricsBefore, metricsAfter:shell.performance?.() ?? null,
                nodes:document.querySelectorAll("*").length,
                candidates:document.querySelectorAll(selector).length,
                visibleMasks:[...document.querySelectorAll("[style]")].filter(element => {
                    const rect=element.getBoundingClientRect();
                    return element.style.getPropertyValue("mask-image") && rect.width && rect.height
                        && rect.right>0 && rect.bottom>0 && rect.left<innerWidth && rect.top<innerHeight;
                }).length
            };
        })()`) as Sample;
    }
    finally
    {
        await window.close();
    }
}

export function summary(values: number[]): { median: number; p95: number; max: number }
{
    const sorted = [...values].sort((left, right) => left - right);
    return { median: sorted[Math.floor(sorted.length / 2)]!, p95: sorted[Math.ceil(sorted.length * 0.95) - 1]!, max: sorted.at(-1)! };
}

