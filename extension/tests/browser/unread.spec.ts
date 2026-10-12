import { test, expect } from "./harness.js";

test.describe("Unread Receipts & Badge Counters", () => {
    test("renders unread badges and highlighted classes accurately", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Room 'dev' starts with unread = 1
        const devRoomBtn = page.locator('button[data-kind="room"][data-id="dev"]');
        await expect(devRoomBtn).toHaveClass(/unread/);
        await expect(devRoomBtn.locator(".badge")).toHaveText("1");

        // Room 'general' starts with unread = 0 (no badge, no unread class)
        const generalRoomBtn = page.locator('button[data-kind="room"][data-id="general"]');
        await expect(generalRoomBtn).not.toHaveClass(/unread/);
        await expect(generalRoomBtn.locator(".badge")).toHaveCount(0);

        // Profile 'reviewer' DM starts with unread = 1
        const reviewerDmBtn = page.locator('button[data-kind="dm"][data-id="reviewer"]');
        await expect(reviewerDmBtn).toHaveClass(/unread/);
        await expect(reviewerDmBtn.locator(".badge")).toHaveText("1");

        // Profile 'architect' DM starts with unread = 0
        const architectDmBtn = page.locator('button[data-kind="dm"][data-id="architect"]');
        await expect(architectDmBtn).not.toHaveClass(/unread/);
        await expect(architectDmBtn.locator(".badge")).toHaveCount(0);

        // Human pings item starts with humanEvents = 1
        const pingsBtn = page.locator('.nav-item[data-action="pings"]');
        await expect(pingsBtn.locator(".badge")).toHaveText("1");
    });

    test("clears room unread badge deterministically upon selection", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const devRoomBtn = page.locator('button[data-kind="room"][data-id="dev"]');
        await expect(devRoomBtn.locator(".badge")).toHaveText("1");

        // Click to view room 'dev'
        await devRoomBtn.click();

        // Harness receives select action and clears unread
        const selectAction = await harness.waitForAction((a) => a.type === "select" && a.destination.id === "dev");
        expect(selectAction).toMatchObject({
            type: "select",
            destination: { kind: "room", id: "dev" },
        });

        // Badge is removed and unread class cleared
        await expect(devRoomBtn.locator(".badge")).toHaveCount(0);
        await expect(devRoomBtn).not.toHaveClass(/unread/);
        await expect(devRoomBtn).toHaveClass(/active/);
    });

    test("clears DM unread badge deterministically upon selection", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const reviewerDmBtn = page.locator('button[data-kind="dm"][data-id="reviewer"]');
        await expect(reviewerDmBtn.locator(".badge")).toHaveText("1");

        // Click to view reviewer DM
        await reviewerDmBtn.click();

        const selectAction = await harness.waitForAction((a) => a.type === "select" && a.destination.id === "reviewer");
        expect(selectAction.type).toBe("select");

        // Badge is removed
        await expect(reviewerDmBtn.locator(".badge")).toHaveCount(0);
        await expect(reviewerDmBtn).not.toHaveClass(/unread/);
        await expect(reviewerDmBtn).toHaveClass(/active/);
    });

    test("clears human pings counter upon selection", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const pingsBtn = page.locator('.nav-item[data-action="pings"]');
        await expect(pingsBtn.locator(".badge")).toHaveText("1");

        // Click pings
        await pingsBtn.click();

        const selectAction = await harness.waitForAction((a) => a.type === "select" && a.destination.kind === "pings");
        expect(selectAction.type).toBe("select");

        // Counter cleared
        await expect(pingsBtn.locator(".badge")).toHaveCount(0);
        await expect(pingsBtn).toHaveClass(/active/);
    });

    test("dynamically increments unread badge when background messages arrive for unselected rooms", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Currently on general room
        const devRoomBtn = page.locator('button[data-kind="room"][data-id="dev"]');
        await expect(devRoomBtn.locator(".badge")).toHaveText("1");

        // Add 2 incoming messages to dev room from background
        harness.addIncomingEntry(
            { kind: "room", id: "dev" },
            { id: "msg-dev-bg-1", ts: Date.now(), from: "architect", text: "Background update 1", room: "dev" },
        );
        harness.addIncomingEntry(
            { kind: "room", id: "dev" },
            { id: "msg-dev-bg-2", ts: Date.now(), from: "architect", text: "Background update 2", room: "dev" },
        );

        // Badge counter updates dynamically to 3
        await expect(devRoomBtn.locator(".badge")).toHaveText("3");
        await expect(devRoomBtn).toHaveClass(/unread/);

        // Clicking clears the badge
        await devRoomBtn.click();
        await expect(devRoomBtn.locator(".badge")).toHaveCount(0);
        await expect(devRoomBtn).not.toHaveClass(/unread/);
    });
});
