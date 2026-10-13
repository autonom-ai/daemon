const memoryStorage = new Map<string, string>();

/**
 * Safely retrieves a value from localStorage with full SecurityError / DOMException protection.
 * Falls back to in-memory session cache and then to the specified default value.
 */
export function safeGetStorage(key: string, fallback = ""): string
{
    try
    {
        if (typeof localStorage !== "undefined" && localStorage !== null)
        {
            const value = localStorage.getItem(key);
            if (value !== null)
            {
                return value;
            }
        }
    }
    catch
    {
        // Suppress SecurityError, DOMException, or restricted sandbox access
    }
    return memoryStorage.get(key) ?? fallback;
}

/**
 * Safely writes a value to localStorage and updates in-memory cache with full SecurityError protection.
 */
export function safeSetStorage(key: string, value: string): void
{
    try
    {
        if (typeof localStorage !== "undefined" && localStorage !== null)
        {
            localStorage.setItem(key, value);
        }
    }
    catch
    {
        // Suppress SecurityError, DOMException, QuotaExceededError, or sandbox restrictions
    }
    memoryStorage.set(key, value);
}
