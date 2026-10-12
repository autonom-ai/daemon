import { test, expect } from "./harness.js";

test.describe("Empirical Challenger Stress Suite: Settings, Secrets, Model Picker, and Multi-Room Unread Determinism", () => {

    test("Settings Dashboard: handles invalid and extreme inputs, enforcing bounds and error feedback", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Navigate to Settings dashboard
        const settingsBtn = page.locator("button[data-action='settings']");
        await expect(settingsBtn).toBeVisible();
        await settingsBtn.click();

        const settingsView = page.locator("#settings-view");
        await expect(settingsView).toBeVisible();

        // 1. Connection Card: inspect input constraints
        const portInput = settingsView.locator("input[name='port']");
        await expect(portInput).toHaveAttribute("type", "number");
        await expect(portInput).toHaveAttribute("min", "1");
        await expect(portInput).toHaveAttribute("max", "65535");
        await expect(portInput).toHaveAttribute("required", "");

        const pollInput = settingsView.locator("input[name='pollIntervalMs']");
        await expect(pollInput).toHaveAttribute("type", "number");
        await expect(pollInput).toHaveAttribute("min", "500");
        await expect(pollInput).toHaveAttribute("max", "10000");
        await expect(pollInput).toHaveAttribute("required", "");

        // 2. Test negative port and out-of-range port via form validation
        await portInput.fill("-1");
        const isPortValidNegative = await portInput.evaluate((el: HTMLInputElement) => el.checkValidity());
        expect(isPortValidNegative).toBe(false);

        await portInput.fill("70000");
        const isPortValidTooHigh = await portInput.evaluate((el: HTMLInputElement) => el.checkValidity());
        expect(isPortValidTooHigh).toBe(false);

        // Restore valid port
        await portInput.fill("8081");
        expect(await portInput.evaluate((el: HTMLInputElement) => el.checkValidity())).toBe(true);

        // 3. Test out-of-range poll intervals
        await pollInput.fill("100");
        const isPollTooLow = await pollInput.evaluate((el: HTMLInputElement) => el.checkValidity());
        expect(isPollTooLow).toBe(false);

        await pollInput.fill("20000");
        const isPollTooHigh = await pollInput.evaluate((el: HTMLInputElement) => el.checkValidity());
        expect(isPollTooHigh).toBe(false);

        // Restore valid poll interval
        await pollInput.fill("2000");
        expect(await pollInput.evaluate((el: HTMLInputElement) => el.checkValidity())).toBe(true);

        // 4. Submit valid connection settings and verify host dispatch
        const saveConnectionBtn = settingsView.locator("form#connection-form button[type='submit']");
        await saveConnectionBtn.click();

        const savedAction = await harness.waitForAction((a) => a.type === "saveSettings");
        expect(savedAction).toMatchObject({
            type: "saveSettings",
            settings: expect.objectContaining({
                port: 8081,
                pollIntervalMs: 2000,
                defaultModel: "swe-2-medium",
            }),
        });

        // 5. Card 3: Daemon settings form submission and failure recovery
        const daemonForm = settingsView.locator("form#daemon-form");
        await expect(daemonForm).toBeVisible();

        // Simulate host rejection of invalid daemon values
        harness.setNextActionResult("saveDaemon", false, "Compaction thresholds must be two or three increasing positive token counts.");
        const saveDaemonBtn = daemonForm.locator("button[type='submit']");
        await saveDaemonBtn.click();

        // Verify error toast
        const toast = page.locator("#toast");
        await expect(toast).toBeVisible();
        await expect(toast).toContainText("Compaction thresholds must be two or three increasing positive token counts.");
        await expect(toast).toHaveClass(/error/);
    });

    test("Secret Masking: API keys are strictly masked and never leaked in DOM or state", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Open settings
        await page.locator("button[data-action='settings']").click();
        const settingsView = page.locator("#settings-view");
        await expect(settingsView).toBeVisible();

        const routingCard = settingsView.locator("#card-routing");
        await expect(routingCard).toBeVisible();

        // 1. Password input attributes
        const keyInput = routingCard.locator("input[name='routerKey']");
        await expect(keyInput).toBeVisible();
        await expect(keyInput).toHaveAttribute("type", "password");
        await expect(keyInput).toHaveAttribute("readonly", "");
        await expect(keyInput).toHaveAttribute("placeholder", "••••••••••••••••");

        // 2. Ensure value property is completely empty (never populated into the DOM)
        const inputValue = await keyInput.evaluate((el: HTMLInputElement) => el.value);
        expect(inputValue).toBe("");

        // 3. Search entire HTML tree for any occurrence of secret substrings
        const wholeHtml = await page.content();
        expect(wholeHtml).not.toContain("private-test-key");
        expect(wholeHtml).not.toContain("sk-or-v1");
        expect(wholeHtml).not.toContain("OPENROUTER_API_KEY");

        // 4. Test clicking 'Configure OpenRouter key' dispatches action without exposing secret
        const configureBtn = routingCard.locator("button[data-action='configureKey']");
        await expect(configureBtn).toBeVisible();
        await configureBtn.click();

        const action = await harness.waitForAction((a) => a.type === "configureKey");
        expect(action.type).toBe("configureKey");

        // 5. Host simulated completion toast
        harness.pushMessage({ type: "result", action: "configureKey", ok: true, error: "" });
        const toast = page.locator("#toast");
        await expect(toast).toBeVisible();
        await expect(toast).toContainText("OpenRouter key configured.");
    });

    test("Model Picker: robust defaults to swe-2-medium when offline, empty catalog, or varied families", async ({ page, harness }) => {
        // Test case A: Catalog is completely empty (offline / no models returned)
        harness.state.models = [];
        await page.goto(harness.baseUrl);

        // Select general room to view composer
        await page.locator('button[data-kind="room"][data-id="general"]').click();

        const composerModel = page.locator("#composer-model");
        await expect(composerModel).toBeVisible();

        // Verify fallback model is swe-2-medium
        await expect(composerModel).toHaveValue("swe-2-medium");
        const optionsEmpty = await composerModel.locator("option").allTextContents();
        expect(optionsEmpty.some((t) => t.includes("SWE-2 Medium") || t.includes("swe-2-medium"))).toBe(true);

        // Check Settings dashboard defaultModel dropdown as well
        await page.locator("button[data-action='settings']").click();
        const settingsDefaultModel = page.locator("select[name='defaultModel']");
        await expect(settingsDefaultModel).toBeVisible();
        await expect(settingsDefaultModel).toHaveValue("swe-2-medium");

        // Navigate back to conversation
        await page.locator("#settings-dashboard button[data-action='back']").first().click();

        // Test case B: Multi-family catalog with adversarial HTML characters
        harness.state.models = [
            { id: "swe-2-medium", label: "SWE-2 Medium", family: "SWE-2", cost: "Free" },
            { id: "gpt-4o", label: "GPT-4o", family: "OpenAI", cost: "$$$" },
            { id: "claude-3-5-sonnet", label: "Claude 3.5 Sonnet", family: "Anthropic", cost: "$$$" },
            { id: "xss-model-test", label: "XSS <img src=x onerror=1>", family: "Hacker & Family", cost: "0" },
        ];
        harness.pushMessage({
            type: "state",
            state: harness.state,
        });

        // Re-select room to refresh composer
        await page.locator('button[data-kind="room"][data-id="general"]').click();

        // Verify optgroups render correctly for each family
        const optgroups = await composerModel.locator("optgroup").all();
        expect(optgroups.length).toBeGreaterThanOrEqual(3);

        // Verify adversarial model label is escaped and no script was executed
        const xssOption = composerModel.locator("option[value='xss-model-test']");
        await expect(xssOption).toBeAttached();
        const xssText = await xssOption.textContent();
        expect(xssText).toContain("XSS <img src=x onerror=1>");

        // Verify canary script execution did not occur
        const xssRan = await page.evaluate(() => (window as unknown as { __xss_model_ran?: boolean }).__xss_model_ran);
        expect(xssRan).toBeUndefined();
    });

    test("Unread Clearing Determinism: multi-room badges isolate correctly and clear deterministically", async ({ page, harness }) => {
        // Setup initial multi-room unread state
        const generalRoom = harness.state.daemon.rooms.find((r) => r.name === "general")!;
        generalRoom.unread = 0;

        const devRoom = harness.state.daemon.rooms.find((r) => r.name === "dev")!;
        devRoom.unread = 3;

        // Add a third room 'ops' with 7 unread
        if (!harness.state.daemon.rooms.some((r) => r.name === "ops")) {
            harness.state.daemon.rooms.push({
                name: "ops",
                count: 10,
                unread: 7,
                lastTs: Date.now(),
                membership: { owner: "human", admins: [], involved: null },
            });
        }

        // Add reviewer profile with 4 unread
        const reviewerProf = harness.state.daemon.profiles.find((p) => p.name === "reviewer")!;
        reviewerProf.unread = 4;

        await page.goto(harness.baseUrl);

        // 1. Verify initial unread badges across rooms and profiles
        const devBtn = page.locator('button[data-kind="room"][data-id="dev"]');
        const opsBtn = page.locator('button[data-kind="room"][data-id="ops"]');
        const reviewerBtn = page.locator('button[data-kind="dm"][data-id="reviewer"]');

        await expect(devBtn.locator(".unread-badge")).toHaveText("3");
        await expect(opsBtn.locator(".unread-badge")).toHaveText("7");
        await expect(reviewerBtn.locator(".unread-badge")).toHaveText("4");

        // 2. Click 'dev' room: 'dev' badge clears immediately; 'ops' and 'reviewer' remain untouched
        await devBtn.click();
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(opsBtn.locator(".unread-badge")).toHaveText("7");
        await expect(reviewerBtn.locator(".unread-badge")).toHaveText("4");

        // 3. Background message arrives for 'ops': increments 'ops' badge to 8 without affecting 'dev'
        harness.addIncomingEntry({ kind: "room", id: "ops" }, {
            id: "msg-ops-new",
            ts: Date.now(),
            from: "architect",
            text: "High priority alert on ops",
            room: "ops",
        });

        await expect(opsBtn.locator(".unread-badge")).toHaveText("8");
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(reviewerBtn.locator(".unread-badge")).toHaveText("4");

        // 4. Background message arrives for currently selected 'dev' room
        harness.addIncomingEntry({ kind: "room", id: "dev" }, {
            id: "msg-dev-current",
            ts: Date.now(),
            from: "architect",
            text: "Live update while user is looking at dev",
            room: "dev",
        });

        // Because 'dev' is actively selected and read, its unread badge stays 0
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);

        // 5. Switch to 'ops' room: 'ops' badge clears immediately; 'reviewer' remains 4
        await opsBtn.click();
        await expect(opsBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(reviewerBtn.locator(".unread-badge")).toHaveText("4");

        // 6. Switch to 'reviewer' DM: 'reviewer' badge clears immediately
        await reviewerBtn.click();
        await expect(reviewerBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(opsBtn.locator(".unread-badge")).toHaveCount(0);

        // 7. Trigger rapid clicks between all three and verify no state flickering or desync
        for (let i = 0; i < 3; i++) {
            await devBtn.click();
            await opsBtn.click();
            await reviewerBtn.click();
        }

        // All viewed destinations remain at 0 unread
        await expect(devBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(opsBtn.locator(".unread-badge")).toHaveCount(0);
        await expect(reviewerBtn.locator(".unread-badge")).toHaveCount(0);
    });

});
