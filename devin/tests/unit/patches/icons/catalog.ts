import { iconByteLimit } from "../../../../launcher/patches/icons/assets";
import { IconCatalog } from "../../../../launcher/patches/icons/catalog";

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, type RequestListener } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { pathToFileURL } from "node:url";

const svg = '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1v1H0z"/></svg>';
const encoded = `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;

async function registry(context: TestContext, agents: unknown[]): Promise<string>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-icons-"));
    context.after(() => rm(root, { force: true, recursive: true }));
    const path = join(root, "registry.json");
    await writeFile(path, JSON.stringify({ agents }));
    return path;
}

async function endpoint(context: TestContext, listener: RequestListener): Promise<string>
{
    const server = createServer(listener);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    context.after(() => new Promise<void>((resolve, reject) =>
    {
        server.closeAllConnections();
        server.close((error) => error ? reject(error) : resolve());
    }));
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    return `http://127.0.0.1:${address.port}`;
}

test("the catalog converts registered icons and keeps the registry byte-for-byte unchanged", async (context) =>
{
    const url = await endpoint(context, (_request, response) =>
    {
        response.setHeader("Content-Type", "image/svg+xml; charset=utf-8");
        response.end(svg);
    });
    const path = await registry(context, []);
    const file = join(path, "..", "icon.svg");
    await writeFile(file, svg);
    await writeFile(path, JSON.stringify({ agents: [
        { id: "antigravity", icon: `${url}/antigravity.svg` },
        { id: "relative", icon: "icon.svg" },
        { id: "absolute", icon: file },
        { id: "file", icon: pathToFileURL(file).href },
        { id: "percent", icon: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}` },
        { id: "base64", icon: encoded },
    ] }, null, 4));
    const before = await readFile(path);
    const icons = await new IconCatalog(path).read();
    for (const provider of ["antigravity", "relative", "absolute", "file", "percent", "base64"])
        assert.equal(icons[provider], encoded);
    assert.match(icons["devin-autonom"]!, /^data:image\/svg\+xml;base64,/);
    assert.deepEqual(await readFile(path), before);
});

test("local changes reload and removed providers prune their shared source cache", async (context) =>
{
    let requests = 0;
    const url = await endpoint(context, (_request, response) =>
    {
        requests++;
        response.setHeader("Content-Type", "image/svg+xml");
        response.end(svg);
    });
    const agents = [{ id: "remote", icon: `${url}/icon.svg` }, { id: "local", icon: "icon.svg" }];
    const path = await registry(context, agents);
    const file = join(path, "..", "icon.svg");
    await writeFile(file, svg);
    const catalog = new IconCatalog(path);
    await catalog.read();
    const changed = `${svg}\n`;
    await writeFile(file, changed);
    const icons = await catalog.read();
    assert.equal(icons.local, `data:image/svg+xml;base64,${Buffer.from(changed).toString("base64")}`);
    assert.equal(requests, 1);
    await rm(file);
    assert.equal((await catalog.read()).local, icons.local);
    await writeFile(file, changed);
    await writeFile(path, JSON.stringify({ agents: [] }));
    assert.deepEqual(Object.keys(await catalog.read()), ["devin-autonom"]);
    await writeFile(path, JSON.stringify({ agents }));
    await catalog.read();
    assert.equal(requests, 2);
});

test("concurrent reads and providers share requests within four active downloads", async (context) =>
{
    let requests = 0;
    let active = 0;
    let maximum = 0;
    const url = await endpoint(context, (_request, response) =>
    {
        requests++;
        maximum = Math.max(maximum, ++active);
        setTimeout(() =>
        {
            active--;
            response.setHeader("Content-Type", "image/svg+xml");
            response.end(svg);
        }, 20);
    });
    const agents = Array.from({ length: 8 }, (_, index) => ({ id: `agent-${index}`, icon: `${url}/${index}.svg` }));
    agents.push({ id: "duplicate", icon: `${url}/0.svg` });
    const catalog = new IconCatalog(await registry(context, agents));
    const first = catalog.read();
    assert.equal(catalog.read(), first);
    const icons = await first;
    assert.equal(requests, 8);
    assert.ok(maximum <= 4);
    assert.equal(icons.duplicate, encoded);
    await catalog.read();
    assert.equal(requests, 8);
});

test("redirect, byte and MIME failures are isolated and failures are cached without leaking URLs", async (context) =>
{
    const requests = new Map<string, number>();
    const url = await endpoint(context, (request, response) =>
    {
        requests.set(request.url!, (requests.get(request.url!) ?? 0) + 1);
        if (request.url === "/loop?private-token")
        {
            response.writeHead(302, { Location: "/loop?private-token" });
            response.end();
        }
        else if (request.url === "/large")
            response.end(Buffer.alloc(iconByteLimit + 1));
        else if (request.url === "/header")
        {
            response.writeHead(200, { "Content-Length": iconByteLimit + 1 });
            response.end();
        }
        else
        {
            response.setHeader("Content-Type", "text/html");
            response.end("<html/>");
        }
    });
    const agents = ["loop?private-token", "large", "header", "html"].map((name) =>
        ({ id: name.split("?")[0], icon: `${url}/${name}` }));
    agents.push({ id: "good", icon: encoded });
    const warnings: string[] = [];
    const catalog = new IconCatalog(await registry(context, agents), (message) => warnings.push(message));
    assert.equal((await catalog.read()).good, encoded);
    assert.equal(requests.get("/loop?private-token"), 4);
    const count = [...requests.values()].reduce((sum, value) => sum + value, 0);
    await catalog.read();
    assert.equal([...requests.values()].reduce((sum, value) => sum + value, 0), count);
    assert.equal(warnings.length, 4);
    assert.ok(warnings.every((message) => !message.includes(url) && !message.includes("private-token")));
});

test("a stalled registry batch has one three-second deadline and stays within four requests", async (context) =>
{
    let requests = 0;
    const url = await endpoint(context, () => requests++);
    const path = await registry(context, Array.from({ length: 8 }, (_, index) =>
        ({ id: `slow-${index}`, icon: `${url}/${index}.svg` })));
    const started = performance.now();
    const icons = await new IconCatalog(path).read();
    assert.ok(performance.now() - started < 4500);
    assert.ok(requests <= 4);
    assert.deepEqual(Object.keys(icons), ["devin-autonom"]);
});

test("invalid data and missing files do not suppress a valid registered Autonom icon", async (context) =>
{
    const path = await registry(context, [
        { id: "invalid", icon: "data:image/svg+xml;base64,%%%" },
        { id: "oversized", icon: `data:image/png;base64,${Buffer.alloc(iconByteLimit + 1).toString("base64")}` },
        { id: "missing", icon: "missing.svg" },
        { id: "devin-autonom", icon: encoded },
    ]);
    assert.deepEqual(await new IconCatalog(path).read(), { "devin-autonom": encoded });
});
