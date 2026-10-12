import { test, expect } from "./harness.js";

test.describe("Messages Lifecycle", () => {
    test("renders initial room messages and metadata", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Header shows room info
        await expect(page.locator(".conversation-title")).toHaveText("general");
        await expect(page.locator(".conversation-subtitle")).toContainText("messages");

        // Initial messages in #general
        const messages = page.locator("#messages article.message");
        await expect(messages).toHaveCount(2);

        // First message from architect
        const firstMsg = messages.nth(0);
        await expect(firstMsg.locator(".message-meta strong")).toHaveText("architect");
        await expect(firstMsg.locator(".markdown")).toContainText("Welcome to the team room!");

        // Second message from reviewer
        const secondMsg = messages.nth(1);
        await expect(secondMsg.locator(".message-meta strong")).toHaveText("reviewer");
        await expect(secondMsg.locator(".markdown")).toContainText("Looking forward to working together.");
    });

    test("merges consecutive messages from the same author", async ({ page, harness }) => {
        // Add consecutive message from reviewer
        harness.entries.get("room:general")?.push({
            id: "msg-gen-3",
            ts: Date.now(),
            from: "reviewer",
            text: "And here is a follow-up message.",
            room: "general",
        });

        await page.goto(harness.baseUrl);

        const messages = page.locator("#messages article.message");
        await expect(messages).toHaveCount(3);

        const thirdMsg = messages.nth(2);
        await expect(thirdMsg).toHaveClass(/merged/);
        await expect(thirdMsg.locator(".avatar-placeholder")).toBeVisible();
        await expect(thirdMsg.locator(".markdown")).toContainText("And here is a follow-up message.");
    });

    test("submits message using Enter key and updates conversation", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        await expect(composer).toBeEnabled();

        await composer.fill("Hello everyone, starting the sprint!");
        await composer.press("Enter");

        // Action was captured by harness
        const postAction = await harness.waitForAction((a) => a.type === "post" && a.text.includes("sprint"));
        expect(postAction).toMatchObject({
            type: "post",
            source: "room",
            target: "general",
            text: "Hello everyone, starting the sprint!",
            ping: [],
        });

        // Textarea cleared after submission
        await expect(composer).toHaveValue("");

        // New message rendered in conversation view
        const messages = page.locator("#messages article.message");
        await expect(messages).toHaveCount(3);
        const lastMsg = messages.nth(2);
        await expect(lastMsg).toHaveClass(/human/);
        await expect(lastMsg.locator(".message-meta strong")).toHaveText("human");
        await expect(lastMsg.locator(".markdown")).toContainText("Hello everyone, starting the sprint!");
    });

    test("submits message using send button", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        const sendBtn = page.locator("#send-button");

        await composer.fill("Sent via button click.");
        await expect(sendBtn).toBeEnabled();
        await sendBtn.click();

        const postAction = await harness.waitForAction((a) => a.type === "post" && a.text.includes("button click"));
        expect(postAction.type).toBe("post");

        await expect(composer).toHaveValue("");
        await expect(page.locator("#messages")).toContainText("Sent via button click.");
    });

    test("preserves newline when Shift+Enter is pressed without submitting", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        await composer.fill("Line 1");
        await composer.press("Shift+Enter");
        await composer.type("Line 2");

        // Textarea contains both lines
        const value = await composer.inputValue();
        expect(value).toContain("Line 1");
        expect(value).toContain("Line 2");

        // No post action was sent
        expect(harness.capturedActions.filter((a) => a.type === "post")).toHaveLength(0);
    });

    test("extracts ping mentions from room message text", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        await composer.fill("Hey @architect and @reviewer, please review this!");
        await composer.press("Enter");

        const postAction = await harness.waitForAction((a) => a.type === "post" && a.text.includes("@architect"));
        if (postAction.type === "post") {
            expect(postAction.ping).toEqual(expect.arrayContaining(["architect", "reviewer"]));
            expect(postAction.ping).toHaveLength(2);
        }
    });

    test("ignores non-existent profile mentions in ping list", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        await composer.fill("Mentioning @unknownProfile who does not exist");
        await composer.press("Enter");

        const postAction = await harness.waitForAction((a) => a.type === "post" && a.text.includes("@unknownProfile"));
        if (postAction.type === "post") {
            expect(postAction.ping).toHaveLength(0);
        }
    });

    test("handles DM message submission and ping-recipient toggle", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Click on architect DM in navigation
        await page.locator('button[data-kind="dm"][data-id="architect"]').click();

        await expect(page.locator(".conversation-title")).toHaveText("architect");
        await expect(page.locator(".conversation-subtitle")).toContainText("Direct message");

        // Ping recipient checkbox is checked by default
        const pingCheckbox = page.locator("#ping-recipient");
        await expect(pingCheckbox).toBeVisible();
        await expect(pingCheckbox).toBeChecked();

        const composer = page.locator("#composer-text");

        // Send with ping checkbox checked
        await composer.fill("Message with ping enabled");
        await composer.press("Enter");

        const action1 = await harness.waitForAction((a) => a.type === "post" && a.text === "Message with ping enabled");
        if (action1.type === "post") {
            expect(action1.source).toBe("dm");
            expect(action1.target).toBe("architect");
            expect(action1.ping).toEqual(["architect"]);
        }

        // Uncheck ping checkbox
        await pingCheckbox.uncheck();
        await expect(pingCheckbox).not.toBeChecked();

        await composer.fill("Message with ping disabled");
        await composer.press("Enter");

        const action2 = await harness.waitForAction((a) => a.type === "post" && a.text === "Message with ping disabled");
        if (action2.type === "post") {
            expect(action2.source).toBe("dm");
            expect(action2.target).toBe("architect");
            expect(action2.ping).toEqual([]);
        }
    });

    test("renders bidirectional real-time incoming messages", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await expect(page.locator("#messages article.message")).toHaveCount(2);

        // Simulate incoming message pushed from backend while user is viewing room
        harness.addIncomingEntry(
            { kind: "room", id: "general" },
            {
                id: "msg-live-1",
                ts: Date.now(),
                from: "architect",
                text: "Incoming message from autonomous agent!",
                room: "general",
            },
        );

        // UI receives event on poll and renders message
        await expect(page.locator("#messages")).toContainText("Incoming message from autonomous agent!");
        await expect(page.locator("#messages article.message")).toHaveCount(3);
    });
});
