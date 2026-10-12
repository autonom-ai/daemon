import { test, expect } from "./harness.js";

test.describe("Tool Calls & Transcript Display", () => {
    test("renders tool call cards, reasoning thoughts, and formats arguments", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        // Switch to session-1
        await page.locator('button[data-kind="session"][data-id="session-1"]').click();
        await expect(page.locator(".conversation-title")).toHaveText("architect");

        // Reasoning thought card
        const thoughtCard = page.locator("#messages details.thought-card");
        await expect(thoughtCard).toHaveCount(1);
        await expect(thoughtCard.locator("summary")).toContainText("Reasoning");

        // Expanding reasoning thought card displays thought markdown
        await thoughtCard.locator("summary").click();
        await expect(thoughtCard).toHaveAttribute("open", "");
        await expect(thoughtCard.locator(".markdown")).toContainText("Analyzing workspace tools and running test execution.");

        // Tool cards
        const toolCards = page.locator("#messages details.tool-card");
        await expect(toolCards).toHaveCount(2);

        // First tool card: exec
        const execCard = toolCards.nth(0);
        await expect(execCard.locator("summary span")).toHaveText("exec");
        await expect(execCard.locator("summary code")).toHaveText("python3 -m pytest -q");

        // Second tool card: mcp with stripped prefix
        const mcpCard = toolCards.nth(1);
        await expect(mcpCard.locator("summary span")).toHaveText("read_events");
    });

    test("expands tool drawer to inspect formatted JSON input and observation results", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await page.locator('button[data-kind="session"][data-id="session-1"]').click();

        const execCard = page.locator("#messages details.tool-card").nth(0);
        // Initially collapsed
        await expect(execCard).not.toHaveAttribute("open", "");

        // Expand tool card
        await execCard.locator("summary").click();
        await expect(execCard).toHaveAttribute("open", "");

        // Inspect Input section
        const inputSection = execCard.locator(".tool-section").nth(0);
        await expect(inputSection.locator(".eyebrow")).toHaveText("Input");
        await expect(inputSection.locator("pre")).toContainText('"command": "python3 -m pytest -q"');

        // Inspect Result section
        const resultSection = execCard.locator(".tool-section").nth(1);
        await expect(resultSection.locator(".eyebrow")).toHaveText("Result");
        await expect(resultSection.locator("pre")).toContainText("12 passed in 0.04s");

        // Collapse tool card
        await execCard.locator("summary").click();
        await expect(execCard).not.toHaveAttribute("open", "");
    });

    test("retains expanded tool drawer state across real-time conversation updates", async ({ page, harness }) => {
        await page.goto(harness.baseUrl);

        await page.locator('button[data-kind="session"][data-id="session-1"]').click();

        const execCard = page.locator("#messages details.tool-card").nth(0);
        await execCard.locator("summary").click();
        await expect(execCard).toHaveAttribute("open", "");

        // Simulate new message added to transcript while tool drawer is open
        const tr = harness.transcripts.get("session:session-1");
        if (tr) {
            tr.messages.push({
                role: "assistant",
                content: "Subsequent update following the tool completion.",
                timestamp: Date.now(),
            });
            harness.pushMessage({
                type: "conversation",
                destination: { kind: "session", id: "session-1" },
                transcript: tr,
                entries: [],
            });
        }

        // New message renders
        await expect(page.locator("#messages")).toContainText("Subsequent update following the tool completion.");

        // Expanded card retains open state
        await expect(execCard).toHaveAttribute("open", "");
    });

    test("renders permission card and handles approval and denial decisions", async ({ page, harness }) => {
        // Add pending permission for session-1
        harness.addPermission({
            id: "perm-test-1",
            session: "session-1",
            tool: "terminal_write",
            input: { command: "npm run deploy" },
            createdAt: Date.now(),
        });

        await page.goto(harness.baseUrl);
        await page.locator('button[data-kind="session"][data-id="session-1"]').click();

        // Permission card is visible
        const permCard = page.locator("#messages .permission-card");
        await expect(permCard).toBeVisible();
        await expect(permCard.locator("h3")).toContainText("Permission needed · terminal_write");
        await expect(permCard.locator("pre")).toContainText('"command": "npm run deploy"');

        // Click allow once button
        const allowBtn = permCard.locator('button[data-decision="approve"]');
        await expect(allowBtn).toBeVisible();
        await allowBtn.click();

        const permAction = await harness.waitForAction((a) => a.type === "permission" && a.id === "perm-test-1");
        expect(permAction).toMatchObject({
            type: "permission",
            id: "perm-test-1",
            decision: "approve",
        });

        // Permission card is removed
        await expect(page.locator("#messages .permission-card")).toHaveCount(0);
    });
});
