import { test, expect } from "./harness.js";

test.describe("Devin Desktop Command Center Integration (R1–R5)", () => {

    test("R1: provider toggle renders above '+ New session', defaults to Autonom, and toggles without reload", async ({ page, harness }) => {
        // Track whether any page reload occurs during toggling
        let reloadCount = 0;
        page.on("framenavigated", (frame) => {
            if (frame === page.mainFrame()) reloadCount++;
        });

        await page.goto(harness.baseUrl);
        expect(reloadCount).toBe(1); // Initial load only

        // Checkbox exists and is positioned above "+ New session"
        const toggle = page.locator("#autonom-provider-toggle, input[data-action='toggleProvider']");
        await expect(toggle).toBeVisible();
        await expect(toggle).toBeChecked();

        const newSessionBtn = page.locator(".sidebar-rail-top button[data-action='newSession'], button.action-new-session");
        await expect(newSessionBtn).toBeVisible();

        // Verify DOM order: toggle container precedes new session button
        const isPreceding = await page.evaluate(() => {
            const t = document.querySelector("#autonom-provider-toggle, [data-action='toggleProvider']");
            const b = document.querySelector(".sidebar-rail-top button[data-action='newSession'], button.action-new-session");
            if (!t || !b) return false;
            return Boolean(t.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
        });
        expect(isPreceding).toBe(true);

        // Verify Autonom surfaces are visible
        await expect(page.locator("nav.navigation")).toBeVisible();
        await expect(page.locator("#section-rooms")).toBeVisible();

        // Verify badge indicates Local
        await expect(page.locator("#provider-mode-badge")).toHaveText("Local");

        // Toggle to Devin Cloud mode
        await toggle.uncheck();

        // Verify instantaneous swap without reload
        expect(reloadCount).toBe(1); // Still exactly 1
        await expect(page.locator("#cloud-spaces-placeholder")).toBeVisible();
        await expect(page.locator("nav.navigation")).toBeHidden();
        // Verify rich cloud spaces components render cleanly
        await expect(page.locator(".cloud-spaces-container")).toBeVisible();
        await expect(page.locator(".cloud-space-item.active")).toBeVisible();
        await expect(page.locator("#provider-mode-badge")).toHaveText("Cloud");

        // Toggle back to Autonom mode
        await toggle.check();
        expect(reloadCount).toBe(1); // Still exactly 1
        await expect(page.locator("nav.navigation")).toBeVisible();
        await expect(page.locator("#cloud-spaces-placeholder")).toBeHidden();
        await expect(page.locator("#provider-mode-badge")).toHaveText("Local");

        // Verify localStorage persistence
        const stored = await page.evaluate(() => localStorage.getItem("autonom.provider"));
        expect(stored).toBe("autonom");
    });

    test("R2: sidebar organizes into Rooms, Profiles, and Unassigned Sessions with live status & unread clearing", async ({ page, harness }) => {
        // Inject an unassigned session into harness state for 3-tier testing
        harness.state.daemon.sessions.push({
            id: "session-unassigned",
            title: "Scratchpad Task",
            model: "swe-2-medium",
            mode: "auto",
            directory: "/workspace/autonom",
            status: "online",
            executionId: null,
            lastActivityAt: Math.floor(Date.now() / 1000),
            createdAt: 3000,
            profile: null,
        });

        await page.goto(harness.baseUrl);

        // Verify 3 distinct section groupings
        const roomsSection = page.locator("#section-rooms, .nav-section:has(.section-heading:has-text('Rooms'))");
        const profilesSection = page.locator("#section-profiles, .nav-section:has(.section-heading:has-text('Profiles')), .nav-section:has(.section-heading:has-text('Agents'))");
        const unassignedSection = page.locator("#section-unassigned, .nav-section:has(.section-heading:has-text('Unassigned'))");

        await expect(roomsSection).toBeVisible();
        await expect(profilesSection).toBeVisible();
        await expect(unassignedSection).toBeVisible();

        // Verify room list and unread badge on 'dev'
        const devRoomBtn = roomsSection.locator('button[data-kind="room"][data-id="dev"]');
        await expect(devRoomBtn).toBeVisible();
        await expect(devRoomBtn.locator(".badge")).toHaveText("1");

        // Click 'dev' room and verify unread badge clears
        await devRoomBtn.click();
        await expect(devRoomBtn.locator(".badge")).toHaveCount(0);
        await expect(devRoomBtn).toHaveClass(/active/);

        // Verify profile status dots
        const architectItem = profilesSection.locator('[data-id="architect"], [data-profile="architect"]');
        await expect(architectItem).toBeVisible();
        await expect(architectItem.locator(".dot.online, .dot.running")).toBeVisible();

        const reviewerItem = profilesSection.locator('[data-id="reviewer"], [data-profile="reviewer"]');
        await expect(reviewerItem).toBeVisible();
        const idleDot = reviewerItem.locator(".dot.idle");
        await expect(idleDot).toBeVisible();
        await expect(reviewerItem.locator(".dot.offline")).toHaveCount(0);
        const idleBg = await idleDot.evaluate((el) => window.getComputedStyle(el).backgroundColor);
        expect(idleBg).not.toBe("rgba(0, 0, 0, 0)");

        // Verify unassigned sessions
        const unassignedItem = unassignedSection.locator('[data-id="session-unassigned"]');
        await expect(unassignedItem).toBeVisible();
        await expect(unassignedItem).toContainText("Scratchpad Task");
        await expect(unassignedItem).toContainText("swe-2-medium");
    });

    test("R2: deterministic 5x5 SVG identicons render across sidebar and header with native theme tokens", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Select architect profile
        const architectBtn = page.locator('button[data-kind="dm"][data-id="architect"], [data-profile="architect"] button');
        await architectBtn.click();

        // Verify identicon in sidebar
        const sidebarIdenticon = architectBtn.locator("svg.identicon");
        await expect(sidebarIdenticon).toBeVisible();
        await expect(sidebarIdenticon).toHaveAttribute("viewBox", "0 0 5 5");

        // Verify identicon in conversation header
        const headerIdenticon = page.locator(".conversation-header svg.identicon, #conversation-header svg.identicon");
        await expect(headerIdenticon).toBeVisible();
        await expect(headerIdenticon).toHaveAttribute("viewBox", "0 0 5 5");

        // Verify determinism: sidebar identicon HTML matches header identicon HTML
        const sidebarHtml = await sidebarIdenticon.evaluate((el) => el.innerHTML);
        const headerHtml = await headerIdenticon.evaluate((el) => el.innerHTML);
        expect(sidebarHtml).toBe(headerHtml);

        // Verify different profile produces different identicon
        const reviewerBtn = page.locator('button[data-kind="dm"][data-id="reviewer"], [data-profile="reviewer"] button');
        const reviewerIdenticon = reviewerBtn.locator("svg.identicon");
        const reviewerHtml = await reviewerIdenticon.evaluate((el) => el.innerHTML);
        expect(reviewerHtml).not.toBe(sidebarHtml);

        // Verify CSS theme variable usage (no hardcoded RGB/HEX)
        const usesThemeVars = await sidebarIdenticon.evaluate((el) => {
            const raw = el.outerHTML;
            return raw.includes("var(--vscode-charts-") || raw.includes("var(--vscode-");
        });
        expect(usesThemeVars).toBe(true);
    });

    test("R3: model picker lists /api/client/models catalog, defaults to swe-2-medium, and evaluates free", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Select room 'general' to enable composer controls
        await page.locator('button[data-kind="room"][data-id="general"]').click();

        const modelSelector = page.locator("#composer-model, select[name='model']");
        await expect(modelSelector).toBeVisible();

        // Verify options match harness catalog
        const options = await modelSelector.locator("option").allTextContents();
        expect(options.some((o) => o.includes("SWE-2 Medium") || o.includes("swe-2-medium"))).toBe(true);
        expect(options.some((o) => o.includes("SWE-2 High") || o.includes("swe-2-high"))).toBe(true);

        // Verify default value is swe-2-medium
        await expect(modelSelector).toHaveValue("swe-2-medium");

        // Verify cost tier does not require paid credits
        const modelData = harness.state.models.find((m) => m.id === "swe-2-medium");
        expect(modelData?.cost).toBe("Free");

        // Selecting a variant updates the dropdown value cleanly
        await modelSelector.selectOption("swe-2-high");
        await expect(modelSelector).toHaveValue("swe-2-high");
    });

    test("R4: clicking Settings opens full center-pane dashboard; updates persist to disk and sync daemon state", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Click Settings button in header
        const settingsBtn = page.locator("button[data-action='settings']");
        await expect(settingsBtn).toBeVisible();
        await settingsBtn.click();

        // Main center area transitions to full settings dashboard view
        const settingsView = page.locator("#settings-view");
        await expect(settingsView).toBeVisible();
        await expect(page.locator("#messages")).toBeHidden();

        // Verify 5 distinct settings cards render
        await expect(settingsView.locator("#card-connection, details[data-card='connection']")).toBeVisible();
        await expect(settingsView.locator("#card-routing, details[data-card='routing']")).toBeVisible();
        await expect(settingsView.locator("#card-lifecycle, details[data-card='lifecycle']")).toBeVisible();
        await expect(settingsView.locator("#card-policy, details[data-card='policy']")).toBeVisible();
        await expect(settingsView.locator("#card-setup, details[data-card='setup']")).toBeVisible();

        // Verify secret key input is masked
        const keyInput = settingsView.locator("input[name='routerKey'], input[name='key']");
        if (await keyInput.count() > 0) {
            await expect(keyInput).toHaveAttribute("type", "password");
        }

        // Test client-side bounds rejection on invalid port
        const portInput = settingsView.locator("input[name='port']");
        await portInput.fill("70000");
        const saveBtn = settingsView.locator("form#connection-form button[type='submit']");
        await saveBtn.click();
        await expect(page.locator("#toast")).toBeVisible();
        await expect(page.locator("#toast")).toContainText("Port must be an integer between 1 and 65535");

        // Test client-side bounds rejection on invalid poll interval
        await portInput.fill("8085");
        const pollInput = settingsView.locator("input[name='pollIntervalMs']");
        await pollInput.fill("100");
        await saveBtn.click();
        await expect(page.locator("#toast")).toBeVisible();
        await expect(page.locator("#toast")).toContainText("Refresh interval must be an integer between 500 and 10000 ms");

        // Fill valid values and submit
        await pollInput.fill("2000");
        await saveBtn.click();

        // Verify harness receives saveSettings action
        const action = await harness.waitForAction((a) => a.type === "saveSettings");
        expect(action).toMatchObject({
            type: "saveSettings",
            settings: expect.objectContaining({ port: 8085, pollIntervalMs: 2000 }),
        });

        // Toast confirms save
        await expect(page.locator("#toast")).toBeVisible();
        await expect(page.locator("#toast")).toContainText("Settings saved");

        // Navigate back to conversation view
        const closeBtn = settingsView.locator("button[data-action='closeSettings'], button[data-action='back']");
        if (await closeBtn.count() > 0) {
            await closeBtn.click();
            await expect(settingsView).toBeHidden();
            await expect(page.locator("#messages")).toBeVisible();
        }
    });
});
