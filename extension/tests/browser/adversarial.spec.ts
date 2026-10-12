import { test, expect } from "./harness.js";

test.describe("Adversarial & Stress Testing", () => {
    test("escapes HTML and prevents script execution across message bodies", async ({ page, harness }) => {
        // Collect page errors
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        harness.entries.set("room:general", [
            {
                id: "xss-1",
                ts: Date.now(),
                from: "architect",
                text: `<script>window.__xss_payload_executed = true;</script>
<img src="invalid-url" onerror="window.__xss_payload_executed = true;">
<a href="javascript:window.__xss_payload_executed=true">Click exploit</a>`,
                room: "general",
            },
        ]);

        await page.goto(harness.baseUrl);

        // Verify window.__xss_payload_executed was never set
        const executed = await page.evaluate(() => (window as unknown as { __xss_payload_executed?: boolean }).__xss_payload_executed);
        expect(executed).toBeUndefined();

        // Verify script tag was not injected into DOM as an executable element
        const scriptElements = await page.locator('#messages script').count();
        expect(scriptElements).toBe(0);

        // Verify raw HTML was escaped and displayed as text
        await expect(page.locator("#messages")).toContainText("<script>");
        await expect(page.locator("#messages")).toContainText("<img src=");

        expect(pageErrors).toHaveLength(0);
    });

    test("escapes dangerous HTML characters in user names and room names", async ({ page, harness }) => {
        const xssRoom = "<script>window.__room_xss=true</script>";
        harness.state.daemon.rooms.push({
            name: xssRoom,
            count: 0,
            unread: 0,
            lastTs: null,
            membership: { owner: "human", admins: [], involved: null },
        });

        await page.goto(harness.baseUrl);

        const xssExecuted = await page.evaluate(() => (window as unknown as { __room_xss?: boolean }).__room_xss);
        expect(xssExecuted).toBeUndefined();

        // Check nav label renders escaped text
        const roomBtn = page.locator(`button[data-kind="room"][data-id="${xssRoom}"]`);
        await expect(roomBtn).toBeVisible();
        await expect(roomBtn.locator(".nav-label")).toHaveText(xssRoom);
    });

    test("blocks markdown image rendering to prevent remote asset leaking", async ({ page, harness }) => {
        harness.entries.set("room:general", [
            {
                id: "img-exploit-1",
                ts: Date.now(),
                from: "reviewer",
                text: "Here is an image: ![Exploit Image](https://example.com/tracking-pixel.png)",
                room: "general",
            },
        ]);

        await page.goto(harness.baseUrl);

        // No img tag rendered in #messages
        const imgCount = await page.locator("#messages img").count();
        expect(imgCount).toBe(0);

        // Renders image alt text in brackets
        await expect(page.locator("#messages")).toContainText("[Exploit Image]");
        await expect(page.locator("#messages")).not.toContainText("https://example.com/tracking-pixel.png");
    });

    test("handles extreme text length without layout crash or freezing", async ({ page, harness }) => {
        const longText = "A".repeat(40000);
        harness.entries.set("room:general", [
            {
                id: "long-1",
                ts: Date.now(),
                from: "architect",
                text: longText,
                room: "general",
            },
        ]);

        await page.goto(harness.baseUrl);

        const messages = page.locator("#messages");
        await expect(messages).toBeVisible();

        // Message body is present and container maintains scroll capability
        const messageCount = await messages.locator("article.message").count();
        expect(messageCount).toBe(1);

        const scrollHeight = await messages.evaluate((el) => el.scrollHeight);
        expect(scrollHeight).toBeGreaterThan(0);
    });

    test("survives rapid navigation switching during active event polling", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        await page.goto(harness.baseUrl);

        const destinations = [
            { kind: "room", id: "general" },
            { kind: "room", id: "dev" },
            { kind: "dm", id: "architect" },
            { kind: "dm", id: "reviewer" },
        ];

        for (let round = 0; round < 3; round++) {
            for (const d of destinations) {
                const item = page.locator(`button[data-kind="${d.kind}"][data-id="${d.id}"]`);
                await item.dispatchEvent("click");
            }
        }

        // Settle on general room
        const generalBtn = page.locator('button[data-kind="room"][data-id="general"]');
        await generalBtn.click();

        await expect(page.locator(".conversation-title")).toHaveText("general");
        await expect(generalBtn).toHaveClass(/active/);
        expect(pageErrors).toHaveLength(0);
    });

    test("gracefully tolerates malformed and corrupted event payloads", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        await page.goto(harness.baseUrl);
        await expect(page.locator(".conversation-title")).toHaveText("general");

        // Push various malformed payloads over /events
        harness.pushMessage(null as unknown as import("../../source/protocol.js").HostMessage);
        harness.pushMessage({} as unknown as import("../../source/protocol.js").HostMessage);
        harness.pushMessage({ type: "unknown_future_type", data: "corrupted" } as unknown as import("../../source/protocol.js").HostMessage);
        harness.pushMessage({ type: 123 } as unknown as import("../../source/protocol.js").HostMessage);

        // Wait to ensure all corrupted events are processed by poll
        await page.waitForTimeout(150);

        // Push valid message to verify webview is still reactive and healthy
        harness.addIncomingEntry(
            { kind: "room", id: "general" },
            { id: "recovery-1", ts: Date.now(), from: "architect", text: "Recovered and still operational", room: "general" },
        );

        await expect(page.locator("#messages")).toContainText("Recovered and still operational");
        expect(pageErrors).toHaveLength(0);
    });
});
