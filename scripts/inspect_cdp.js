const { chromium } = require("playwright");

async function main() {
    const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
    const contexts = browser.contexts();
    console.log(`Contexts count: ${contexts.length}`);
    for (let ci = 0; ci < contexts.length; ci++) {
        const ctx = contexts[ci];
        const pages = ctx.pages();
        console.log(`Context ${ci} pages: ${pages.length}`);
        for (let pi = 0; pi < pages.length; pi++) {
            const page = pages[pi];
            console.log(`\nPage ${pi}: title="${await page.title()}", url="${page.url()}"`);
            const frames = page.frames();
            console.log(`  Frames: ${frames.length}`);
            for (let fi = 0; fi < frames.length; fi++) {
                const frame = frames[fi];
                console.log(`    Frame ${fi}: name="${frame.name()}", url="${frame.url()}"`);
            }
        }
    }
    await browser.close();
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
