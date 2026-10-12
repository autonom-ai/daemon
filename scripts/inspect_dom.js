const { chromium } = require("playwright");

async function main() {
    const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
    const page = browser.contexts()[0].pages()[0];

    console.log("Page URL:", page.url());
    console.log("Page Title:", await page.title());

    // Check if there are webviews or iframes
    const iframes = await page.evaluate(() => {
        const frames = Array.from(document.querySelectorAll("iframe, webview"));
        return frames.map(f => ({
            tag: f.tagName,
            id: f.id,
            className: f.className,
            src: f.src,
            rect: f.getBoundingClientRect()
        }));
    });
    console.log("Iframes/Webviews:", JSON.stringify(iframes, null, 2));

    // Check what is in the main window
    const rootStructure = await page.evaluate(() => {
        function summarize(el, depth = 0) {
            if (depth > 4) return "...";
            const children = Array.from(el.children).map(c => summarize(c, depth + 1));
            return {
                tag: el.tagName,
                id: el.id,
                className: el.className,
                children: children.length > 0 ? children : undefined
            };
        }
        return summarize(document.body);
    });
    console.log("Body structure:", JSON.stringify(rootStructure, null, 2).slice(0, 2000));

    await browser.close();
}

main().catch(console.error);
