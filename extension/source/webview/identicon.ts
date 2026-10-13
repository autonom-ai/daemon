/**
 * Deterministic 32-bit FNV-1a hash algorithm.
 * Produces an unsigned 32-bit integer from any input string.
 */
export function fnv1a(str: string): number
{
    let hash = 2166136261;
    for (let i = 0; i < str.length; i++)
    {
        hash ^= str.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
    }
    return hash >>> 0;
}

/**
 * Normalizes case and whitespace, then computes FNV-1a hash.
 */
export function hashProfileName(name: string): number
{
    return fnv1a((name || "").trim().toLowerCase());
}

/**
 * Palette mapped strictly to Devin Desktop / VS Code theme custom properties.
 * Contains exclusively CSS variable expressions (no raw hex codes).
 */
export const IDENTICON_PALETTE = [
    "var(--vscode-charts-blue)",
    "var(--vscode-charts-green)",
    "var(--vscode-charts-purple)",
    "var(--vscode-charts-orange)",
    "var(--vscode-charts-yellow)",
    "var(--vscode-charts-red)",
    "var(--vscode-charts-lines)",
    "var(--vscode-terminal-ansiCyan)",
];

/**
 * Generates a deterministic, 5x5 horizontally symmetric SVG identicon.
 *
 * Geometry:
 * - 5 columns, 5 rows (viewBox="0 0 5 5").
 * - Horizontal reflection: columns 0, 1, 2 are mirrored to 4 and 3.
 * - 3 unique columns * 5 rows = 15 bits consumed from the FNV-1a hash.
 * - Color is selected by (hash % IDENTICON_PALETTE.length).
 */
export function generateIdenticonSvg(name: string, size = 22, className = ""): string
{
    const hash = hashProfileName(name || "autonom");
    const color = IDENTICON_PALETTE[hash % IDENTICON_PALETTE.length];

    const rects: string[] = [];
    for (let c = 0; c < 3; c++)
    {
        for (let r = 0; r < 5; r++)
        {
            const bitIndex = c * 5 + r;
            const bit = (hash >>> bitIndex) & 1;
            if (bit === 1)
            {
                rects.push(`<rect x="${c}" y="${r}" width="1" height="1" fill="${color}" />`);
                if (c < 2)
                {
                    rects.push(`<rect x="${4 - c}" y="${r}" width="1" height="1" fill="${color}" />`);
                }
            }
        }
    }

    if (rects.length === 0)
    {
        rects.push(`<rect x="2" y="2" width="1" height="1" fill="${color}" />`);
    }

    const classes = ["identicon", className].filter(Boolean).join(" ");
    return `<svg class="${classes}" width="${size}" height="${size}" viewBox="0 0 5 5" aria-hidden="true">${rects.join("")}</svg>`;
}

export function identicon(name: string, size = 22, className = ""): string
{
    return generateIdenticonSvg(name, size, className);
}
