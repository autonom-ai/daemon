import { CdpClient, type CdpSession } from "../launcher/cdp/client";

export async function connectBrowser(): Promise<{ client: CdpClient; close(): void }>
{
    const port = process.env.AUTONOM_TEST_CDP_PORT ?? "9222";
    const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(5000) });
    const identity = await response.json() as { webSocketDebuggerUrl: string };
    const socket = new WebSocket(identity.webSocketDebuggerUrl);
    await new Promise<void>((resolve, reject) =>
    {
        const timer = setTimeout(() => reject(new Error("Desktop CDP connection timed out.")), 5000);
        socket.addEventListener("open", () =>
        {
            clearTimeout(timer);
            resolve();
        }, { once: true });
        socket.addEventListener("error", () =>
        {
            clearTimeout(timer);
            reject(new Error("Desktop CDP connection failed."));
        }, { once: true });
    });
    const client = new CdpClient({
        send: (message) => socket.send(JSON.stringify(message)),
        onMessage(listener)
        {
            const receive = (event: MessageEvent) => listener(JSON.parse(String(event.data)));
            socket.addEventListener("message", receive);
            return () => socket.removeEventListener("message", receive);
        },
        onClose(listener)
        {
            socket.addEventListener("close", listener);
            return () => socket.removeEventListener("close", listener);
        },
        close: () => socket.close(),
    });
    return {
        client,
        close(): void
        {
            client.close();
            socket.close();
        },
    };
}

export async function connectWindow(targetId: string): Promise<{ session: CdpSession; close(): Promise<void> }>
{
    const browser = await connectBrowser();
    const client = browser.client;
    const target = (await client.targets()).find((entry) => entry.id === targetId);
    if (target?.type !== "page" || !target.url.startsWith("vscode-file://vscode-app/"))
    {
        browser.close();
        throw new Error("Select a separate Devin Desktop workbench target for live tests.");
    }

    const session = await client.attach(targetId);
    return {
        session,
        async close(): Promise<void>
        {
            await session.detach();
            browser.close();
        },
    };
}

export async function click(session: CdpSession, selector: string): Promise<void>
{
    const point = await session.evaluate(`(() => {
        const element = [...document.querySelectorAll(${JSON.stringify(selector)})].find(element => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
        });
        const rect = element?.getBoundingClientRect();
        if (!rect || rect.width <= 0 || rect.height <= 0) throw new Error("The native control is not visible");
        return {x:rect.x+rect.width/2, y:rect.y+rect.height/2};
    })()`) as { x: number; y: number };
    await session.request("Input.dispatchMouseEvent", { type: "mousePressed", ...point, button: "left", clickCount: 1 });
    await session.request("Input.dispatchMouseEvent", { type: "mouseReleased", ...point, button: "left", clickCount: 1 });
}
