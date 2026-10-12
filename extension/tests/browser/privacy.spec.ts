import { test, expect } from "./harness.js";

test.describe("Privacy & Destination Isolation", () => {
    test("strictly isolates messages across rooms, DMs, and pings", async ({ page, harness }) => {
        // Configure unique secrets per conversation stream
        harness.entries.set("room:general", [
            { id: "gen-1", ts: 1000, from: "architect", text: "GENERAL_ROOM_SECRET_001", room: "general" },
        ]);
        harness.entries.set("room:dev", [
            { id: "dev-1", ts: 1000, from: "architect", text: "DEV_ROOM_SECRET_002", room: "dev" },
        ]);
        harness.entries.set("dm:architect", [
            { id: "dm-arch-1", ts: 1000, from: "architect", text: "ARCHITECT_DM_SECRET_003", to: "human" },
        ]);
        harness.entries.set("dm:reviewer", [
            { id: "dm-rev-1", ts: 1000, from: "reviewer", text: "REVIEWER_DM_SECRET_004", to: "human" },
        ]);
        harness.entries.set("pings:human", [
            { id: "ping-1", ts: 1000, from: "architect", text: "HUMAN_PINGS_SECRET_005", to: "human" },
        ]);

        await page.goto(harness.baseUrl);

        const chatColumn = page.locator(".chat-column");

        // 1. In room general: only general secret is visible
        await expect(chatColumn).toContainText("GENERAL_ROOM_SECRET_001");
        await expect(chatColumn).not.toContainText("DEV_ROOM_SECRET_002");
        await expect(chatColumn).not.toContainText("ARCHITECT_DM_SECRET_003");
        await expect(chatColumn).not.toContainText("REVIEWER_DM_SECRET_004");
        await expect(chatColumn).not.toContainText("HUMAN_PINGS_SECRET_005");

        // 2. Switch to room dev
        await page.locator('button[data-kind="room"][data-id="dev"]').click();
        await expect(chatColumn).toContainText("DEV_ROOM_SECRET_002");
        await expect(chatColumn).not.toContainText("GENERAL_ROOM_SECRET_001");
        await expect(chatColumn).not.toContainText("ARCHITECT_DM_SECRET_003");
        await expect(chatColumn).not.toContainText("REVIEWER_DM_SECRET_004");
        await expect(chatColumn).not.toContainText("HUMAN_PINGS_SECRET_005");

        // 3. Switch to architect DM
        await page.locator('button[data-kind="dm"][data-id="architect"]').click();
        await expect(chatColumn).toContainText("ARCHITECT_DM_SECRET_003");
        await expect(chatColumn).not.toContainText("GENERAL_ROOM_SECRET_001");
        await expect(chatColumn).not.toContainText("DEV_ROOM_SECRET_002");
        await expect(chatColumn).not.toContainText("REVIEWER_DM_SECRET_004");
        await expect(chatColumn).not.toContainText("HUMAN_PINGS_SECRET_005");

        // 4. Switch to reviewer DM
        await page.locator('button[data-kind="dm"][data-id="reviewer"]').click();
        await expect(chatColumn).toContainText("REVIEWER_DM_SECRET_004");
        await expect(chatColumn).not.toContainText("GENERAL_ROOM_SECRET_001");
        await expect(chatColumn).not.toContainText("DEV_ROOM_SECRET_002");
        await expect(chatColumn).not.toContainText("ARCHITECT_DM_SECRET_003");
        await expect(chatColumn).not.toContainText("HUMAN_PINGS_SECRET_005");

        // 5. Switch to pings
        await page.locator('.nav-item[data-action="pings"]').click();
        await expect(chatColumn).toContainText("HUMAN_PINGS_SECRET_005");
        await expect(chatColumn).not.toContainText("GENERAL_ROOM_SECRET_001");
        await expect(chatColumn).not.toContainText("DEV_ROOM_SECRET_002");
        await expect(chatColumn).not.toContainText("ARCHITECT_DM_SECRET_003");
        await expect(chatColumn).not.toContainText("REVIEWER_DM_SECRET_004");
    });

    test("drops incoming background messages intended for unselected destinations", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Currently on general room
        await expect(page.locator(".conversation-title")).toHaveText("general");

        // Simulate incoming message arriving in dev room
        harness.addIncomingEntry(
            { kind: "room", id: "dev" },
            { id: "dev-bg-1", ts: Date.now(), from: "architect", text: "UNSELECTED_DEV_CONFIDENTIAL", room: "dev" },
        );

        // Simulate incoming DM arriving for reviewer
        harness.addIncomingEntry(
            { kind: "dm", id: "reviewer" },
            { id: "dm-bg-1", ts: Date.now(), from: "reviewer", text: "UNSELECTED_DM_CONFIDENTIAL", to: "human" },
        );

        // Neither message should appear in current view
        await expect(page.locator(".chat-column")).not.toContainText("UNSELECTED_DEV_CONFIDENTIAL");
        await expect(page.locator(".chat-column")).not.toContainText("UNSELECTED_DM_CONFIDENTIAL");
    });

    test("discards stale conversation responses from mismatched destinations", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // On general room
        await expect(page.locator(".conversation-title")).toHaveText("general");
        await expect(page.locator("#messages")).toContainText("Welcome to the team room!");

        // Inject out-of-order conversation event destined for dev room
        harness.pushMessage({
            type: "conversation",
            destination: { kind: "room", id: "dev" },
            transcript: null,
            entries: [
                { id: "stale-1", ts: Date.now(), from: "architect", text: "STALE_OUT_OF_ORDER_LEAK", room: "dev" },
            ],
        });

        // Wait to allow polling to consume the event
        await page.waitForTimeout(100);

        // Verify leak did not occur
        await expect(page.locator("#messages")).not.toContainText("STALE_OUT_OF_ORDER_LEAK");
        await expect(page.locator("#messages")).toContainText("Welcome to the team room!");
    });

    test("enforces composer disabled state in read-only pings stream", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const composer = page.locator("#composer-text");
        const sendBtn = page.locator("#send-button");

        // In room, composer is enabled
        await expect(composer).toBeEnabled();

        // Switch to pings
        await page.locator('.nav-item[data-action="pings"]').click();
        await expect(page.locator(".conversation-title")).toHaveText("Your pings");

        // In pings, composer and send button are disabled
        await expect(composer).toBeDisabled();
        await expect(sendBtn).toBeDisabled();
    });
});
