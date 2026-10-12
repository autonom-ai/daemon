import { safeGetStorage, safeSetStorage } from "../../source/webview/storage";

import assert from "node:assert/strict";
import { test } from "node:test";

test("safeGetStorage: returns fallback when storage is undefined", () => {
    assert.equal(safeGetStorage("unknown.key", "fallbackValue"), "fallbackValue");
});

test("safeGetStorage and safeSetStorage: handle SecurityError gracefully and use in-memory map", () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    try {
        (globalThis as any).localStorage = {
            getItem() {
                const err = new Error("The operation is insecure.");
                err.name = "SecurityError";
                throw err;
            },
            setItem() {
                const err = new Error("The operation is insecure.");
                err.name = "SecurityError";
                throw err;
            },
        };

        // Even though localStorage throws SecurityError, safeGetStorage returns the fallback
        assert.equal(safeGetStorage("autonom.provider", "autonom"), "autonom");

        // safeSetStorage absorbs the error and sets the in-memory map
        safeSetStorage("autonom.provider", "devin-cloud");

        // Subsequent safeGetStorage retrieves the value from in-memory map
        assert.equal(safeGetStorage("autonom.provider", "autonom"), "devin-cloud");
    } finally {
        (globalThis as any).localStorage = originalLocalStorage;
    }
});
