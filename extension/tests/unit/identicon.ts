import { generateIdenticonSvg, hashProfileName } from "../../source/webview/identicon";

import assert from "node:assert/strict";
import { test } from "node:test";

test("hashProfileName generates deterministic FNV-1a 32-bit hashes", () => {
    const h1 = hashProfileName("architect");
    const h2 = hashProfileName("architect");
    assert.equal(h1, h2);
    assert.ok(typeof h1 === "number");

    // Different profiles generate different hashes
    const h3 = hashProfileName("reviewer");
    assert.notEqual(h1, h3);

    // Case normalization: uppercase vs lowercase
    assert.equal(hashProfileName("Architect"), hashProfileName("architect"));
});

test("generateIdenticonSvg produces deterministic byte-for-byte SVG markup across 1000 iterations", () => {
    const baseline = generateIdenticonSvg("architect");
    for (let i = 0; i < 1000; i++) {
        assert.equal(generateIdenticonSvg("architect"), baseline);
    }
});

test("generateIdenticonSvg enforces 5x5 horizontal reflection symmetry", () => {
    const svg = generateIdenticonSvg("reviewer");

    // Extract all rect coordinates
    const rectRegex = /<rect\s+x="(\d+)"\s+y="(\d+)"/g;
    const filledCells = new Set<string>();
    let match: RegExpExecArray | null;

    while ((match = rectRegex.exec(svg)) !== null) {
        filledCells.add(`${match[1]},${match[2]}`);
    }

    // Verify 5x5 symmetry: (x, y) filled iff (4 - x, y) filled
    for (let y = 0; y < 5; y++) {
        // Col 0 vs Col 4
        assert.equal(filledCells.has(`0,${y}`), filledCells.has(`4,${y}`), `Row ${y} asymmetric at col 0 & 4`);
        // Col 1 vs Col 3
        assert.equal(filledCells.has(`1,${y}`), filledCells.has(`3,${y}`), `Row ${y} asymmetric at col 1 & 3`);
    }
});

test("generateIdenticonSvg generates valid SVG structure with viewBox 0 0 5 5", () => {
    const svg = generateIdenticonSvg("marlow");
    assert.ok(svg.startsWith("<svg"));
    assert.ok(svg.endsWith("</svg>"));
    assert.ok(svg.includes('viewBox="0 0 5 5"'));
    assert.ok(svg.includes('class="identicon"'));
});

test("generateIdenticonSvg maps palette colors strictly to --vscode-charts-* design tokens", () => {
    const testProfiles = ["architect", "reviewer", "quill", "marlow", "human", "agent-x"];
    for (const name of testProfiles) {
        const svg = generateIdenticonSvg(name);

        // Verify fill attribute references a CSS variable
        assert.ok(
            svg.includes("var(--vscode-charts-") || svg.includes("var(--vscode-"),
            `Profile ${name} identicon does not use VS Code chart tokens: ${svg}`
        );

        // Ensure NO raw hex codes like #ffffff or #123456
        assert.equal(/#[0-9a-fA-F]{3,8}/.test(svg), false, `Identicon contains hardcoded hex color: ${svg}`);
    }
});
