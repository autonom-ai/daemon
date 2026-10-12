import { test, expect } from "../browser/harness.js";
import type { Destination, HostMessage } from "../../source/protocol.js";

test.describe("Empirical Stress & Robustness Suite (R1 & R2)", () => {

    test("Stress 1: Rapid-fire switching across 10 destinations in 2s under active state polling without message cross-contamination", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        // Configure 10 distinct destinations with unique markers
        const destinations: Destination[] = [
            { kind: "room", id: "general" },
            { kind: "room", id: "dev" },
            { kind: "room", id: "ops" },
            { kind: "room", id: "security" },
            { kind: "dm", id: "architect" },
            { kind: "dm", id: "reviewer" },
            { kind: "dm", id: "tester" },
            { kind: "dm", id: "deployer" },
            { kind: "session", id: "session-1" },
            { kind: "session", id: "session-2" },
        ];

        // Ensure all rooms exist in harness state
        for (const roomName of ["general", "dev", "ops", "security"]) {
            if (!harness.state.daemon.rooms.some((r) => r.name === roomName)) {
                harness.state.daemon.rooms.push({
                    name: roomName,
                    count: 1,
                    unread: 0,
                    lastTs: Date.now(),
                    membership: { owner: "human", admins: [], involved: null },
                });
            }
        }

        // Ensure all profiles exist in harness state
        for (const profName of ["architect", "reviewer", "tester", "deployer"]) {
            if (!harness.state.daemon.profiles.some((p) => p.name === profName)) {
                harness.state.daemon.profiles.push({
                    name: profName,
                    session: null,
                    managed: true,
                    events: 0,
                    schedules: 0,
                    unread: 0,
                });
            }
        }

        // Populate unique messages for each destination
        const destinationMarkers = new Map<string, string>();
        for (const dest of destinations) {
            const key = `${dest.kind}:${dest.id}`;
            const marker = `UNIQUE_MARKER_${dest.kind.toUpperCase()}_${dest.id.toUpperCase()}`;
            destinationMarkers.set(key, marker);

            if (dest.kind === "room" || dest.kind === "dm") {
                harness.entries.set(key, [
                    {
                        id: `msg-${dest.id}-1`,
                        ts: Date.now() - 5000,
                        from: dest.kind === "dm" ? dest.id : "architect",
                        text: `Payload containing ${marker} for destination ${dest.id}`,
                        ...(dest.kind === "room" ? { room: dest.id } : { to: "human" }),
                    },
                ]);
            } else if (dest.kind === "session") {
                harness.transcripts.set(`session:${dest.id}`, {
                    session: harness.state.daemon.sessions.find((s) => s.id === dest.id) ?? null,
                    execution: null,
                    messages: [
                        {
                            role: "user",
                            content: `User query with ${marker} for ${dest.id}`,
                            timestamp: Date.now() - 5000,
                        },
                        {
                            role: "assistant",
                            content: `Assistant response with ${marker} verified`,
                            timestamp: Date.now() - 4000,
                        },
                    ],
                });
            }
        }

        await page.goto(harness.baseUrl);
        await expect(page.locator(".conversation-title")).toHaveText("general");

        // Install in-browser observer to detect ANY attribution violation
        await page.evaluate((markersJson) => {
            const markers = JSON.parse(markersJson) as Record<string, string>;
            const violations: string[] = [];
            (window as unknown as { __violations: string[] }).__violations = violations;

            const messagesEl = document.getElementById("messages");
            if (!messagesEl) return;

            const observer = new MutationObserver(() => {
                const currentText = messagesEl.textContent || "";
                // Determine current selected destination from active nav item
                const activeBtn = document.querySelector<HTMLButtonElement>(".nav-item.active");
                if (!activeBtn) return;
                const kind = activeBtn.dataset["kind"];
                const id = activeBtn.dataset["id"];
                const currentKey = `${kind}:${id}`;

                for (const [key, marker] of Object.entries(markers)) {
                    if (key !== currentKey && currentText.includes(marker)) {
                        violations.push(`Contamination detected! Destination ${currentKey} contained marker ${marker} from ${key}`);
                    }
                }
            });

            observer.observe(messagesEl, { childList: true, subtree: true, characterData: true });
        }, JSON.stringify(Object.fromEntries(destinationMarkers.entries())));

        // Background state polling generator
        let pollingActive = true;
        const pollLoop = async () => {
            let count = 0;
            while (pollingActive) {
                count++;
                harness.pushMessage({
                    type: "state",
                    state: {
                        ...harness.state,
                    },
                });
                await new Promise((r) => setTimeout(r, 50));
            }
        };
        const pollPromise = pollLoop();

        // Perform rapid-fire switching across 10 destinations within 2 seconds
        const startTime = Date.now();
        // Cycle 2 full rounds across 10 destinations = 20 clicks
        for (let round = 0; round < 2; round++) {
            for (const dest of destinations) {
                const btn = page.locator(`button[data-kind="${dest.kind}"][data-id="${dest.id}"]`);
                await btn.dispatchEvent("click");
                // Micro-delay to simulate rapid clicking within 2 seconds
                await page.waitForTimeout(45);
            }
        }

        const elapsed = Date.now() - startTime;
        expect(elapsed).toBeLessThanOrEqual(2500);

        // Finally settle on 'security' room
        const securityBtn = page.locator(`button[data-kind="room"][data-id="security"]`);
        await securityBtn.dispatchEvent("click");

        // Settle and wait for conversation to render
        const finalMarker = destinationMarkers.get("room:security")!;
        await expect(page.locator("#messages")).toContainText(finalMarker, { timeout: 3000 });
        await expect(page.locator(".conversation-title")).toHaveText("security");

        // Stop polling
        pollingActive = false;
        await pollPromise;

        // Check for any DOM contamination violations recorded by the observer
        const observedViolations = await page.evaluate(() => (window as unknown as { __violations: string[] }).__violations);
        expect(observedViolations).toEqual([]);

        // Explicitly assert that #messages does NOT contain markers from any other destination
        const renderedText = await page.locator("#messages").textContent();
        for (const [key, marker] of destinationMarkers.entries()) {
            if (key === "room:security") {
                expect(renderedText).toContain(marker);
            } else {
                expect(renderedText).not.toContain(marker);
            }
        }

        expect(pageErrors).toHaveLength(0);
    });

    test("Stress 2: Viewport resizing across responsive breakpoints (320px, 450px, 720px, 1000px, 1280px, 1920px) with bounding box determinism", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        await page.goto(harness.baseUrl);
        await expect(page.locator(".conversation-title")).toHaveText("general");

        const breakpoints = [
            { width: 320, height: 600, category: "mobile-min" },
            { width: 450, height: 750, category: "mobile-med" },
            { width: 720, height: 800, category: "mobile-max" },
            { width: 1000, height: 800, category: "tablet-desktop" },
            { width: 1280, height: 900, category: "desktop-standard" },
            { width: 1920, height: 1080, category: "desktop-wide" },
        ];

        for (const bp of breakpoints) {
            await page.setViewportSize({ width: bp.width, height: bp.height });
            await page.waitForTimeout(50); // allow layout recalculation

            // 1. .app-header bounding box
            const header = page.locator(".app-header");
            await expect(header).toBeVisible();
            const headerBox = await header.boundingBox();
            expect(headerBox).not.toBeNull();
            if (headerBox) {
                expect(headerBox.x).toBe(0);
                expect(headerBox.y).toBe(0);
                expect(headerBox.width).toBe(bp.width);
                expect(headerBox.height).toBe(58);
            }

            // 2. .send-button bounding box
            const sendBtn = page.locator("#send-button");
            await expect(sendBtn).toBeVisible();
            const sendBox = await sendBtn.boundingBox();
            expect(sendBox).not.toBeNull();
            if (sendBox) {
                expect(sendBox.width).toBe(29);
                expect(sendBox.height).toBe(29);
                // Must be fully inside viewport horizontally
                expect(sendBox.x).toBeGreaterThanOrEqual(0);
                expect(sendBox.x + sendBox.width).toBeLessThanOrEqual(bp.width);
            }

            // 3. .navigation visibility and bounds
            const navigation = page.locator(".navigation");
            if (bp.width <= 720) {
                // In mobile, navigation should be hidden by default
                await expect(navigation).toBeHidden();
                // When mobile toggle is clicked, navigation opens as overlay
                const mobileToggle = page.locator('button.mobile-toggle');
                await expect(mobileToggle).toBeVisible();
                await mobileToggle.click();
                await expect(navigation).toBeVisible();
                const navBox = await navigation.boundingBox();
                expect(navBox).not.toBeNull();
                if (navBox) {
                    expect(navBox.x).toBe(0);
                    expect(navBox.width).toBe(235);
                    expect(navBox.height).toBeGreaterThan(0);
                }
                // Close navigation
                await mobileToggle.click();
                await expect(navigation).toBeHidden();
            } else {
                // In desktop/tablet, navigation is in-flow visible
                await expect(navigation).toBeVisible();
                const navBox = await navigation.boundingBox();
                expect(navBox).not.toBeNull();
                if (navBox) {
                    expect(navBox.x).toBe(0);
                    const expectedNavWidth = bp.width <= 1150 ? 210 : 224;
                    expect(navBox.width).toBe(expectedNavWidth);
                }
            }

            // 4. .inspector visibility and bounds
            const inspector = page.locator(".inspector");
            if (bp.width <= 1150) {
                // Inspector is hidden by default on narrower screens
                await expect(inspector).toBeHidden();
                // Inspector toggle is visible
                const inspectorToggle = page.locator('button.inspector-toggle');
                await expect(inspectorToggle).toBeVisible();
                await inspectorToggle.click();
                await expect(inspector).toBeVisible();
                const inspBox = await inspector.boundingBox();
                expect(inspBox).not.toBeNull();
                if (inspBox) {
                    expect(inspBox.width).toBe(250);
                    expect(inspBox.x + inspBox.width).toBeLessThanOrEqual(bp.width);
                }
                // Close inspector
                await inspectorToggle.click();
                await expect(inspector).toBeHidden();
            } else {
                // Desktop persistent inspector (> 1150px)
                await expect(inspector).toBeVisible();
                const inspBox = await inspector.boundingBox();
                expect(inspBox).not.toBeNull();
                if (inspBox) {
                    expect(inspBox.width).toBe(236);
                    // Right edge aligns with viewport width
                    expect(Math.abs(inspBox.x + inspBox.width - bp.width)).toBeLessThanOrEqual(1.5);
                }
                // Inspector toggle should NOT be visible in wide desktop
                const inspectorToggle = page.locator('button.inspector-toggle');
                await expect(inspectorToggle).toBeHidden();
            }

            // 5. Assert document has no horizontal overflow/scrolling
            const overflow = await page.evaluate(() => {
                return {
                    scrollWidth: document.documentElement.scrollWidth,
                    clientWidth: document.documentElement.clientWidth,
                };
            });
            expect(overflow.scrollWidth).toBeLessThanOrEqual(bp.width);
        }

        expect(pageErrors).toHaveLength(0);
    });

    test("Stress 3: Rapid modal submissions spamming 'Create room' and 'Add schedule' with debounce verification", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        await page.goto(harness.baseUrl);
        await expect(page.locator(".conversation-title")).toHaveText("general");

        // 3a. Spam clicking "Create room"
        await page.locator('button[data-action="createRoom"]').click();
        const createRoomModal = page.locator("#create-room-form");
        await expect(createRoomModal).toBeVisible();
        await page.locator('input[name="name"]').fill("stress-room-1");

        const roomSubmitBtn = createRoomModal.locator('button[type="submit"]');
        const actionsBeforeRoom = harness.capturedActions.filter((a) => a.type === "createRoom").length;

        // Dispatch 20 rapid clicks
        await page.evaluate(() => {
            const btn = document.querySelector<HTMLButtonElement>('#create-room-form button[type="submit"]');
            if (btn) {
                for (let i = 0; i < 20; i++) {
                    btn.click();
                }
            }
        });

        // Wait for modal to close
        await expect(createRoomModal).toBeHidden();

        // Verify EXACTLY 1 createRoom action was dispatched
        const roomActions = harness.capturedActions.filter((a) => a.type === "createRoom");
        expect(roomActions.length - actionsBeforeRoom).toBe(1);

        // Verify the room now exists in navigation
        await expect(page.locator('button[data-kind="room"][data-id="stress-room-1"]')).toBeVisible();

        // 3b. Spam clicking "Add schedule"
        await page.locator('button[data-action="schedules"][data-profile="architect"]').click();
        const scheduleModal = page.locator("#schedule-form");
        await expect(scheduleModal).toBeVisible();

        const actionsBeforeSched = harness.capturedActions.filter((a) => a.type === "schedule").length;

        // Dispatch 20 rapid clicks
        await page.evaluate(() => {
            const btn = document.querySelector<HTMLButtonElement>('#schedule-form button[type="submit"]');
            if (btn) {
                for (let i = 0; i < 20; i++) {
                    btn.click();
                }
            }
        });

        // Wait for modal to close
        await expect(scheduleModal).toBeHidden();

        // Verify EXACTLY 1 schedule action was dispatched
        const schedActions = harness.capturedActions.filter((a) => a.type === "schedule");
        expect(schedActions.length - actionsBeforeSched).toBe(1);

        // 3c. Error rejection and recovery on rapid submissions
        await page.locator('button[data-action="createRoom"]').click();
        await expect(createRoomModal).toBeVisible();
        await page.locator('input[name="name"]').fill("collision-room");

        // Simulate host rejection
        harness.setNextActionResult("createRoom", false, "Room name already registered");
        const actionsBeforeError = harness.capturedActions.filter((a) => a.type === "createRoom").length;

        await page.evaluate(() => {
            const btn = document.querySelector<HTMLButtonElement>('#create-room-form button[type="submit"]');
            if (btn) {
                for (let i = 0; i < 15; i++) {
                    btn.click();
                }
            }
        });

        // Error toast should appear
        const toast = page.locator("#toast");
        await expect(toast).toBeVisible();
        await expect(toast).toContainText("Room name already registered");

        // Verify only 1 action was dispatched despite 15 clicks
        const errorActions = harness.capturedActions.filter((a) => a.type === "createRoom");
        expect(errorActions.length - actionsBeforeError).toBe(1);

        // Modal should remain open and submit button re-enabled for retry
        await expect(createRoomModal).toBeVisible();
        await expect(roomSubmitBtn).toBeEnabled();

        // Modify input and retry
        await page.locator('input[name="name"]').fill("stress-room-retry");
        await roomSubmitBtn.click();
        await expect(createRoomModal).toBeHidden();
        await expect(page.locator('button[data-kind="room"][data-id="stress-room-retry"]')).toBeVisible();

        expect(pageErrors).toHaveLength(0);
    });

    test("Stress 4: Extreme adversarial inputs (100k chars, nested XSS vectors, surrogate pairs, malformed payloads)", async ({ page, harness }) => {
        const pageErrors: Error[] = [];
        page.on("pageerror", (err) => pageErrors.push(err));

        await page.goto(harness.baseUrl);
        await expect(page.locator(".conversation-title")).toHaveText("general");

        // 4a. 100,000 characters in composer
        const massiveText = "X".repeat(100000);
        await page.locator("#composer-text").fill(massiveText);
        await expect(page.locator("#send-button")).toBeEnabled();

        const postActionPromise = harness.waitForAction((a) => a.type === "post" && a.text.length === 100000);
        await page.locator("#send-button").click();
        const capturedPost = await postActionPromise;
        if (capturedPost.type === "post") {
            expect(capturedPost.text.length).toBe(100000);
        } else {
            throw new Error(`Expected post action, received: ${capturedPost.type}`);
        }

        // Verify message rendered in #messages without freezing
        const messageCount = await page.locator("#messages article.message").count();
        expect(messageCount).toBeGreaterThan(0);
        const scrollHeight = await page.locator("#messages").evaluate((el) => el.scrollHeight);
        expect(scrollHeight).toBeGreaterThan(0);

        // 4b. Nested HTML/script injection vectors
        const maliciousPayload = `
            <div id="nested1">
                <div id="nested2">
                    <script>window.__xss_nested_exploit = true;</script>
                    <img src="https://invalid-host/x.png" onerror="window.__xss_nested_exploit = true;">
                    <svg><a xlink:href="javascript:window.__xss_nested_exploit=true"><animate attributeName="x" onbegin="window.__xss_nested_exploit=true"></a></svg>
                    <iframe src="javascript:window.__xss_nested_exploit=true"></iframe>
                    <object data="javascript:window.__xss_nested_exploit=true"></object>
                </div>
            </div>
            [Malicious Link](javascript:window.__xss_nested_exploit=true)
            [Data Link](data:text/html,<script>window.__xss_nested_exploit=true</script>)
            <a href="javascript:window.__xss_nested_exploit=true" onclick="window.__xss_nested_exploit=true">Injected Anchor</a>
        `;

        harness.addIncomingEntry({ kind: "room", id: "general" }, {
            id: "adv-xss-1",
            ts: Date.now(),
            from: "reviewer",
            text: maliciousPayload,
            room: "general",
        });

        // Wait for update
        await page.waitForTimeout(100);

        // Assert canary was never executed
        const canary = await page.evaluate(() => (window as unknown as { __xss_nested_exploit?: boolean }).__xss_nested_exploit);
        expect(canary).toBeUndefined();

        // Assert no executable elements in #messages
        expect(await page.locator("#messages script").count()).toBe(0);
        expect(await page.locator("#messages iframe").count()).toBe(0);
        expect(await page.locator("#messages object").count()).toBe(0);
        expect(await page.locator("#messages animate").count()).toBe(0);

        // Click any rendered anchors and verify they don't navigate or execute
        const renderedAnchors = page.locator("#messages a");
        const anchorCount = await renderedAnchors.count();
        for (let i = 0; i < anchorCount; i++) {
            await renderedAnchors.nth(i).click({ timeout: 500, force: true });
        }
        const canaryAfterClicks = await page.evaluate(() => (window as unknown as { __xss_nested_exploit?: boolean }).__xss_nested_exploit);
        expect(canaryAfterClicks).toBeUndefined();

        // 4c. Unicode surrogate pairs, RTL overrides, null bytes, zero-width chars
        const unicodePayload = "Surrogate test: \uD83D\uDE00 \uD83D\uDE80 \uD83E\uDDD1\u200D\uD83D\uDCBB RTL: \u202Ereversed\u202C ZWSP: \u200B\u200C\u200D\uFEFF Null: \x00\x01\x1F Lone: \uD800 \uDFFF";
        harness.addIncomingEntry({ kind: "room", id: "general" }, {
            id: "adv-unicode-1",
            ts: Date.now(),
            from: "architect",
            text: unicodePayload,
            room: "general",
        });

        await expect(page.locator("#messages")).toContainText("Surrogate test:");
        await expect(page.locator("#messages")).toContainText("😀");

        // 4d. Malformed and corrupted host messages barrage
        // Verify non-record, empty, primitive, and unknown message types are safely handled
        const malformedPayloads: unknown[] = [
            null,
            undefined,
            "",
            12345,
            true,
            {},
            [],
            { type: null },
            { type: 999 },
            { type: "" },
            { type: "unknown_payload_track_future", data: { deep: [1, 2, 3] } },
            { type: "future_event_type_v2" },
        ];

        for (const malformed of malformedPayloads) {
            harness.pushMessage(malformed as HostMessage);
        }

        // Wait to allow polling to consume all malformed payloads
        await page.waitForTimeout(200);

        // Verify webview is still fully healthy and reactive
        harness.addIncomingEntry({ kind: "room", id: "general" }, {
            id: "recovery-entry-1",
            ts: Date.now(),
            from: "architect",
            text: "SYSTEM_RECOVERY_SUCCESSFUL_VERIFIED",
            room: "general",
        });

        await expect(page.locator("#messages")).toContainText("SYSTEM_RECOVERY_SUCCESSFUL_VERIFIED", { timeout: 3000 });

        // Zero page errors throughout
        expect(pageErrors).toHaveLength(0);
    });

});
