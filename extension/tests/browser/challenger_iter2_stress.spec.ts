import { test, expect } from "./harness.js";

test.describe("Empirical Challenger Iteration 2 Stress Suite", () => {

    test("Settings Form: client-side bounds checking rejects invalid port and pollIntervalMs with error toast and no dispatch", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Open settings view
        const settingsBtn = page.locator("button[data-action='settings']");
        await expect(settingsBtn).toBeVisible();
        await settingsBtn.click();

        const settingsView = page.locator("#settings-view");
        await expect(settingsView).toBeVisible();

        const connectionForm = settingsView.locator("form#connection-form");
        await expect(connectionForm).toBeVisible();

        const portInput = connectionForm.locator("input[name='port']");
        const pollInput = connectionForm.locator("input[name='pollIntervalMs']");
        const saveBtn = connectionForm.locator("button[type='submit']");
        const toastEl = page.locator("#toast");

        // Baseline: clear captured actions
        harness.capturedActions = [];

        // 1. Stress-test port bounds rejection (<1, >65535, NaN, float, whitespace)
        const invalidPorts = ["0", "-1", "-8080", "65536", "99999", "8080.5", "   "];
        for (const badPort of invalidPorts) {
            harness.capturedActions = [];
            await portInput.fill(badPort);
            await pollInput.fill("1000"); // valid poll interval
            await saveBtn.click();

            // Error toast must be displayed with exact bounds message
            await expect(toastEl).toBeVisible();
            await expect(toastEl).toContainText("Port must be an integer between 1 and 65535");
            await expect(toastEl).toHaveClass(/error/);

            // Port input must receive focus
            const portFocused = await page.evaluate(() => {
                const active = document.activeElement;
                const port = document.querySelector<HTMLInputElement>("form#connection-form input[name='port']");
                return active === port;
            });
            expect(portFocused).toBe(true);

            // No saveSettings action dispatched to bridge
            const saveAction = harness.capturedActions.find((a) => a.type === "saveSettings");
            expect(saveAction).toBeUndefined();
        }

        // Test non-numeric string / NaN on port via DOM evaluation
        for (const nonNum of ["abc", "NaN"]) {
            harness.capturedActions = [];
            await portInput.evaluate((el: HTMLInputElement, val) => {
                el.value = val;
                el.dispatchEvent(new Event("input", { bubbles: true }));
            }, nonNum);
            await pollInput.fill("1000");
            await saveBtn.click();

            await expect(toastEl).toBeVisible();
            await expect(toastEl).toContainText("Port must be an integer between 1 and 65535");
            await expect(toastEl).toHaveClass(/error/);

            const saveAction = harness.capturedActions.find((a) => a.type === "saveSettings");
            expect(saveAction).toBeUndefined();
        }

        // 2. Stress-test pollIntervalMs bounds rejection (<500, >10000, float, whitespace)
        const invalidPolls = ["499", "0", "-500", "10001", "50000", "1000.5", "   "];
        await portInput.fill("8080"); // valid port
        for (const badPoll of invalidPolls) {
            harness.capturedActions = [];
            await pollInput.fill(badPoll);
            await saveBtn.click();

            // Error toast must be displayed with exact interval message
            await expect(toastEl).toBeVisible();
            await expect(toastEl).toContainText("Refresh interval must be an integer between 500 and 10000 ms");
            await expect(toastEl).toHaveClass(/error/);

            // Poll input must receive focus
            const pollFocused = await page.evaluate(() => {
                const active = document.activeElement;
                const poll = document.querySelector<HTMLInputElement>("form#connection-form input[name='pollIntervalMs']");
                return active === poll;
            });
            expect(pollFocused).toBe(true);

            // No saveSettings action dispatched
            const saveAction = harness.capturedActions.find((a) => a.type === "saveSettings");
            expect(saveAction).toBeUndefined();
        }

        // Test non-numeric string / NaN on pollIntervalMs via DOM evaluation
        for (const nonNum of ["xyz", "NaN"]) {
            harness.capturedActions = [];
            await pollInput.evaluate((el: HTMLInputElement, val) => {
                el.value = val;
                el.dispatchEvent(new Event("input", { bubbles: true }));
            }, nonNum);
            await saveBtn.click();

            await expect(toastEl).toBeVisible();
            await expect(toastEl).toContainText("Refresh interval must be an integer between 500 and 10000 ms");
            await expect(toastEl).toHaveClass(/error/);

            const saveAction = harness.capturedActions.find((a) => a.type === "saveSettings");
            expect(saveAction).toBeUndefined();
        }

        // 3. Test valid boundary values: port: 1, poll: 500 (lower bounds)
        harness.capturedActions = [];
        await portInput.fill("1");
        await pollInput.fill("500");
        await saveBtn.click();

        const actionLower = await harness.waitForAction((a) => a.type === "saveSettings");
        expect(actionLower).toMatchObject({
            type: "saveSettings",
            settings: expect.objectContaining({ port: 1, pollIntervalMs: 500 }),
        });
        await expect(toastEl).toBeVisible();
        await expect(toastEl).toContainText("Settings saved");

        // 4. Test valid boundary values: port: 65535, poll: 10000 (upper bounds)
        harness.capturedActions = [];
        await portInput.fill("65535");
        await pollInput.fill("10000");
        await saveBtn.click();

        const actionUpper = await harness.waitForAction((a) => a.type === "saveSettings");
        expect(actionUpper).toMatchObject({
            type: "saveSettings",
            settings: expect.objectContaining({ port: 65535, pollIntervalMs: 10000 }),
        });
        await expect(toastEl).toBeVisible();
        await expect(toastEl).toContainText("Settings saved");
    });

    test("Status Dots: idle profiles compute yellow (rgb(204, 167, 0) / var(--yellow)) and override gray cascade", async ({ page, harness }) => {
        // Ensure reviewer profile is bound to an offline session (which resolves to Idle)
        const reviewerSession = harness.state.daemon.sessions.find((s) => s.profile === "reviewer")!;
        reviewerSession.status = "offline";

        // Add an unbound profile to test pure offline styling
        harness.state.daemon.profiles.push({
            name: "unbound-bot",
            session: null,
            managed: true,
            events: 0,
            schedules: 0,
            unread: 0,
        });

        await page.goto(harness.baseUrl);

        // Verify reviewer profile dot has class 'dot idle' and not 'dot offline'
        const reviewerItem = page.locator('#section-profiles button[data-kind="dm"][data-id="reviewer"]');
        await expect(reviewerItem).toBeVisible();
        const idleDot = reviewerItem.locator(".dot.idle");
        await expect(idleDot).toBeVisible();
        await expect(reviewerItem.locator(".dot.offline")).toHaveCount(0);

        // Check computed opacity is 1 (not 0.6)
        const idleOpacity = await idleDot.evaluate((el) => window.getComputedStyle(el).opacity);
        expect(idleOpacity).toBe("1");

        // 1. Verify computed color with default fallback variable
        const fallbackBg = await idleDot.evaluate((el) => window.getComputedStyle(el).backgroundColor);
        // Default #d9b981 is rgb(217, 185, 129)
        expect(fallbackBg).not.toBe("rgba(0, 0, 0, 0)");
        expect(fallbackBg).not.toBe("rgb(105, 111, 124)"); // Not gray (--faint)

        // 2. Set Devin Desktop / VS Code native token --vscode-charts-yellow: #cca700 (rgb(204, 167, 0))
        await page.evaluate(() => {
            document.documentElement.style.setProperty("--vscode-charts-yellow", "#cca700");
        });
        const computedYellow = await idleDot.evaluate((el) => window.getComputedStyle(el).backgroundColor);
        expect(computedYellow).toBe("rgb(204, 167, 0)");

        // 3. Stress-test CSS cascade resilience on compound classes:
        // Even if both .offline and .idle classes are present (.dot.offline.idle or .dot.idle.offline),
        // the rule must compute to yellow rgb(204, 167, 0), NOT faint gray.
        const compoundBg1 = await page.evaluate(() => {
            const testSpan = document.createElement("span");
            testSpan.className = "dot offline idle";
            document.body.appendChild(testSpan);
            const bg = window.getComputedStyle(testSpan).backgroundColor;
            testSpan.remove();
            return bg;
        });
        expect(compoundBg1).toBe("rgb(204, 167, 0)");

        const compoundBg2 = await page.evaluate(() => {
            const testSpan = document.createElement("span");
            testSpan.className = "dot idle offline";
            document.body.appendChild(testSpan);
            const bg = window.getComputedStyle(testSpan).backgroundColor;
            testSpan.remove();
            return bg;
        });
        expect(compoundBg2).toBe("rgb(204, 167, 0)");

        // 4. Contrast against unbound profile (pure offline) which must compute to gray (--faint)
        const unboundItem = page.locator('#section-profiles button[data-kind="dm"][data-id="unbound-bot"]');
        await expect(unboundItem).toBeVisible();
        const offlineDot = unboundItem.locator(".dot.offline");
        await expect(offlineDot).toBeVisible();
        await expect(unboundItem.locator(".dot.idle")).toHaveCount(0);
        const offlineOpacity = await offlineDot.evaluate((el) => window.getComputedStyle(el).opacity);
        expect(offlineOpacity).toBe("0.6");

        // 5. Contrast against architect profile (active running) which must compute to green
        const architectItem = page.locator('#section-profiles button[data-kind="dm"][data-id="architect"]');
        await expect(architectItem).toBeVisible();
        const runningDot = architectItem.locator(".dot.online.running");
        await expect(runningDot).toBeVisible();
    });

    test("Cloud Toggle UX: rapid clicking and storage restrictions maintain deterministic DOM synchronization", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        const toggle = page.locator("#autonom-provider-toggle");
        await expect(toggle).toBeVisible();
        await expect(toggle).toBeChecked();

        const badge = page.locator("#provider-mode-badge");
        const brand = page.locator("#provider-toggle-brand");
        const label = page.locator(".provider-toggle-label");
        const nav = page.locator("nav.navigation");
        const cloudPlaceholder = page.locator("#cloud-spaces-placeholder");

        // Initial state
        await expect(badge).toHaveText("Local");
        await expect(brand).toContainText("Autonom");
        await expect(label).toHaveClass(/is-autonom/);
        await expect(nav).toBeVisible();
        await expect(cloudPlaceholder).toBeHidden();

        // 1. Rapid click burst stress test (25 clicks -> odd number -> should settle on Devin Cloud)
        for (let i = 0; i < 25; i++) {
            await toggle.click();
        }

        // Verify settled state is Cloud mode
        await expect(toggle).not.toBeChecked();
        await expect(badge).toHaveText("Cloud");
        await expect(brand).toContainText("Devin Cloud");
        await expect(label).toHaveClass(/is-cloud/);
        await expect(nav).toBeHidden();
        await expect(cloudPlaceholder).toBeVisible();
        await expect(page.locator(".cloud-spaces-container")).toBeVisible();
        expect(await page.evaluate(() => localStorage.getItem("autonom.provider"))).toBe("devin-cloud");

        // 2. Click once more (even number of clicks -> returns to Autonom mode)
        await toggle.click();
        await expect(toggle).toBeChecked();
        await expect(badge).toHaveText("Local");
        await expect(brand).toContainText("Autonom");
        await expect(label).toHaveClass(/is-autonom/);
        await expect(nav).toBeVisible();
        await expect(cloudPlaceholder).toBeHidden();
        expect(await page.evaluate(() => localStorage.getItem("autonom.provider"))).toBe("autonom");

        // 3. Storage restriction stress test: simulate SecurityError / DOMException on localStorage
        await page.evaluate(() => {
            window.localStorage.setItem = () => {
                throw new DOMException("The operation is insecure.", "SecurityError");
            };
        });

        // Toggle to Cloud mode under throwing localStorage
        await toggle.click();
        await expect(toggle).not.toBeChecked();
        await expect(badge).toHaveText("Cloud");
        await expect(brand).toContainText("Devin Cloud");
        await expect(nav).toBeHidden();
        await expect(cloudPlaceholder).toBeVisible();

        // Toggle back to Autonom under throwing localStorage
        await toggle.click();
        await expect(toggle).toBeChecked();
        await expect(badge).toHaveText("Local");
        await expect(brand).toContainText("Autonom");
        await expect(nav).toBeVisible();
        await expect(cloudPlaceholder).toBeHidden();

        // Verify zero uncaught errors occurred
        const errors = await page.evaluate(() => (window as unknown as { __captured_errors?: string[] }).__captured_errors ?? []);
        expect(errors).toHaveLength(0);
    });

});
