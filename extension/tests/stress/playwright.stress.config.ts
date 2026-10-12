import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
    testDir: "./",
    testMatch: /.*\.spec\.ts$/,
    timeout: 30000,
    expect: {
        timeout: 5000,
    },
    fullyParallel: false,
    retries: 0,
    reporter: "list",
    use: {
        headless: true,
        actionTimeout: 10000,
        trace: "off",
    },
    projects: [
        {
            name: "chromium",
            use: {
                ...devices["Desktop Chrome"],
            },
        },
    ],
});
