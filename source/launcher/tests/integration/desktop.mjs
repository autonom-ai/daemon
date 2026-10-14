import { once } from "node:events";
import { writeFile } from "node:fs/promises";

const [target, action, ...args] = process.argv.slice(2);
if (!target || !["eval", "click", "screenshot", "close"].includes(action))
    throw new Error("Usage: node tests/integration/desktop.mjs <exact-target-id> eval|click|screenshot|close <argument>");

const port = Number(process.env.AUTONOM_DEBUG_PORT || 9222);
if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("Invalid loopback debug port.");

const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
    signal: AbortSignal.timeout(2000), redirect: "error",
});
const { webSocketDebuggerUrl } = await response.json();
const url = new URL(webSocketDebuggerUrl);
if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1" || url.port !== String(port)
    || !url.pathname.startsWith("/devtools/browser/"))
    throw new Error("Refusing a non-loopback browser endpoint.");

const socket = new WebSocket(url);
await once(socket, "open");
let sequence = 0;
const pending = new Map();
socket.addEventListener("message", (event) =>
{
    const message = JSON.parse(event.data);
    const request = pending.get(message.id);
    if (!request)
        return;

    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error)
        request.reject(new Error(message.error.message));
    else
        request.resolve(message.result);
});
function request(method, params = {}, sessionId)
{
    const id = ++sequence;
    return new Promise((resolve, reject) =>
    {
        const timer = setTimeout(() =>
        {
            pending.delete(id);
            reject(new Error(`Timed out: ${method}`));
        }, 45000);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
}

try
{
    const { targetInfos } = await request("Target.getTargets");
    if (!targetInfos.some((info) => info.targetId === target && ["page", "iframe"].includes(info.type)))
        throw new Error("Exact renderer target not found; no window was controlled.");

    if (action === "close")
        console.log(JSON.stringify(await request("Target.closeTarget", { targetId: target })));
    else
    {
        const { sessionId } = await request("Target.attachToTarget", { targetId: target, flatten: true });
        async function evaluate(expression)
        {
            const result = await request("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
            if (result.exceptionDetails)
                throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);

            return result.result.value;
        }

        try
        {
            if (action === "eval")
                console.log(JSON.stringify(await evaluate(args.join(" ")), null, 2));
            else if (action === "click")
            {
                const point = await evaluate(`(() => {
                    const element = [...document.querySelectorAll(${JSON.stringify(args[0])})]
                        .find(element => element.getBoundingClientRect().width > 0);
                    if (!element) throw new Error("No visible click target");
                    const rect = element.getBoundingClientRect();
                    return {x:rect.x+rect.width/2,y:rect.y+rect.height/2};
                })()`);
                for (const type of ["mousePressed", "mouseReleased"])
                    await request("Input.dispatchMouseEvent", { type, ...point, button: "left", clickCount: 1 }, sessionId);

                console.log(JSON.stringify({ target, clicked: args[0] }));
            }
            else
            {
                const { data } = await request("Page.captureScreenshot", { format: "png" }, sessionId);
                await writeFile(args[0], Buffer.from(data, "base64"), { flag: "wx", mode: 0o600 });
                console.log(JSON.stringify({ target, screenshot: args[0] }));
            }
        }
        finally
        {
            await request("Target.detachFromTarget", { sessionId });
        }
    }
}
finally
{
    socket.close();
}
