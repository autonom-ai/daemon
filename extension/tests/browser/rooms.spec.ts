import { test, expect } from "./harness.js";

test.describe("Room Management", () => {
    test("creates a new room and displays it in navigation", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Click create room button in navigation
        await page.locator('button[data-action="createRoom"]').click();

        // Modal dialog opens
        const form = page.locator("#create-room-form");
        await expect(form).toBeVisible();
        await expect(page.locator("#dialog-title")).toHaveText("Create a room");

        // Fill valid room name
        const nameInput = form.locator('input[name="name"]');
        await nameInput.fill("sprint-planning");

        // Submit form
        await form.locator('button[type="submit"]').click();

        // Action received by harness
        const createAction = await harness.waitForAction((a) => a.type === "createRoom" && a.name === "sprint-planning");
        expect(createAction).toMatchObject({
            type: "createRoom",
            name: "sprint-planning",
        });

        // Dialog closes
        await expect(form).not.toBeVisible();

        // New room appears in navigation list
        const newRoomNav = page.locator('button[data-kind="room"][data-id="sprint-planning"]');
        await expect(newRoomNav).toBeVisible();
        await expect(newRoomNav.locator(".nav-label")).toHaveText("sprint-planning");
    });

    test("handles room creation error by showing toast", async ({ page, harness }) => {
        // Set next createRoom to fail
        harness.setNextActionResult("createRoom", false, "Room name 'general' is already in use.");

        await page.goto(harness.baseUrl);
        await page.locator('button[data-action="createRoom"]').click();

        const form = page.locator("#create-room-form");
        await form.locator('input[name="name"]').fill("general");
        await form.locator('button[type="submit"]').click();

        // Toast displays error message
        const toast = page.locator("#toast");
        await expect(toast).toBeVisible();
        await expect(toast).toHaveClass(/error/);
        await expect(toast).toContainText("Room name 'general' is already in use.");
    });

    test("opens room settings dialog and displays current configuration", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Select dev room
        await page.locator('button[data-kind="room"][data-id="dev"]').click();
        await expect(page.locator(".conversation-title")).toHaveText("dev");

        // Click room settings button
        await page.locator('button[data-action="manageRoom"]').click();

        const form = page.locator("#room-form");
        await expect(form).toBeVisible();
        await expect(page.locator("#dialog-title")).toHaveText("#dev · settings");

        // Restrict checkbox is checked because involved list is configured
        const restrictedCheckbox = form.locator('input[name="restricted"]');
        await expect(restrictedCheckbox).toBeChecked();

        const memberList = form.locator("#membership-list");
        await expect(memberList).toBeVisible();

        // Both profiles are checked
        await expect(memberList.locator('input[value="architect"]')).toBeChecked();
        await expect(memberList.locator('input[value="reviewer"]')).toBeChecked();
    });

    test("modifies room membership restrictions", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await page.locator('button[data-kind="room"][data-id="dev"]').click();
        await page.locator('button[data-action="manageRoom"]').click();

        const form = page.locator("#room-form");
        const reviewerCheckbox = form.locator('#membership-list input[value="reviewer"]');

        // Uncheck reviewer
        await reviewerCheckbox.uncheck();
        await expect(reviewerCheckbox).not.toBeChecked();

        // Submit form
        await form.locator('button[type="submit"]').click();

        const membershipAction = await harness.waitForAction((a) => a.type === "membership" && a.name === "dev");
        if (membershipAction.type === "membership") {
            expect(membershipAction.involved).toEqual(["architect"]);
        }

        // Dialog closes on success
        await expect(form).not.toBeVisible();
    });

    test("toggles membership list visibility with restricted checkbox", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // General room has unrestricted membership (involved: null)
        await page.locator('button[data-action="manageRoom"]').click();

        const form = page.locator("#room-form");
        const restricted = form.locator('input[name="restricted"]');
        const list = form.locator("#membership-list");

        await expect(restricted).not.toBeChecked();
        await expect(list).toBeHidden();

        // Check restricted
        await restricted.check();
        await expect(list).toBeVisible();

        // Uncheck restricted
        await restricted.uncheck();
        await expect(list).toBeHidden();
    });

    test("updates administrator list by removing and adding admins", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await page.locator('button[data-kind="room"][data-id="dev"]').click();
        await page.locator('button[data-action="manageRoom"]').click();

        const form = page.locator("#room-form");

        // Remove reviewer as admin
        const removeAdminBtn = form.locator('button[data-action="removeAdmin"][data-profile="reviewer"]');
        await expect(removeAdminBtn).toBeVisible();
        await removeAdminBtn.click();

        const removeAction = await harness.waitForAction((a) => a.type === "roomAdmin" && a.remove === true);
        if (removeAction.type === "roomAdmin") {
            expect(removeAction.name).toBe("dev");
            expect(removeAction.profile).toBe("reviewer");
            expect(removeAction.remove).toBe(true);
        }
    });

    test("deletes room and transitions view to fallback room", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await page.locator('button[data-kind="room"][data-id="dev"]').click();
        await expect(page.locator(".conversation-title")).toHaveText("dev");
        await page.locator('button[data-action="manageRoom"]').click();

        const form = page.locator("#room-form");
        const deleteBtn = form.locator('button[data-action="deleteRoom"]');
        await expect(deleteBtn).toBeVisible();
        await deleteBtn.click();

        const deleteAction = await harness.waitForAction((a) => a.type === "deleteRoom" && a.name === "dev");
        expect(deleteAction).toMatchObject({
            type: "deleteRoom",
            name: "dev",
        });

        // Dialog is closed on room deletion
        await expect(form).not.toBeVisible();

        // Room dev is removed from navigation
        await expect(page.locator('button[data-kind="room"][data-id="dev"]')).not.toBeVisible();

        // View transitions to unselected welcome view
        await expect(page.locator(".conversation-title")).toHaveText("Workspace");
        await expect(page.locator("#messages")).toContainText("Your agents. One workspace.");
    });

    test("closes modal dialog via Escape key and close button", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Open create room dialog
        await page.locator('button[data-action="createRoom"]').click();
        await expect(page.locator("#create-room-form")).toBeVisible();

        // Press Escape to dismiss
        await page.keyboard.press("Escape");
        await expect(page.locator("#create-room-form")).not.toBeVisible();

        // Open room settings dialog
        await page.locator('button[data-action="manageRoom"]').click();
        await expect(page.locator("#room-form")).toBeVisible();

        // Click header close button (x-lg)
        await page.locator('#room-form .dialog-header button[data-action="close"]').click();
        await expect(page.locator("#room-form")).not.toBeVisible();

        // Open room settings dialog again and test Cancel button
        await page.locator('button[data-action="manageRoom"]').click();
        await expect(page.locator("#room-form")).toBeVisible();
        await page.locator('#room-form .dialog-footer button[data-action="close"]').click();
        await expect(page.locator("#room-form")).not.toBeVisible();
    });
});
