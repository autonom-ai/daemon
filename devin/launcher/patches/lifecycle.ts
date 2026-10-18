export type PatchStatus = {
    name: string;
    state: "installed" | "restored" | "failed" | "skipped";
    errors?: string[];
};

type Entry = {
    target?: object;
    key?: unknown;
    kind?: string;
    apply?: (value: any) => void;
    restore: () => boolean | void;
};

function sameDescriptor(left: PropertyDescriptor | undefined, right: PropertyDescriptor | undefined): boolean
{
    if (!left || !right)
        return left === right;

    return ["configurable", "enumerable", "writable", "value", "get", "set"]
        .every((key) => Object.is(left[key as keyof PropertyDescriptor], right[key as keyof PropertyDescriptor]));
}

/** Owns reversible renderer mutations without claiming another owner's replacements. */
export class Patches
{
    private readonly entries: Entry[] = [];
    private readonly errors: string[] = [];
    private state: PatchStatus["state"] = "installed";
    private restored = false;

    constructor(private readonly name = "native", private readonly report?: (status: PatchStatus) => void)
    { }

    private change<T>(target: object, key: unknown, kind: string, value: T,
        read: () => T, write: (next: T) => void, same: (left: T, right: T) => boolean = Object.is): void
    {
        if (this.restored)
            throw new Error(`The ${this.name} patches are restored.`);

        try
        {
            const existing = this.entries.find((entry) => entry.target === target && entry.kind === kind
                && (entry.key === key || Object.is(entry.key, key)));
            if (existing)
            {
                existing.apply!(value);
                return;
            }

            const original = read();
            if (same(original, value))
                return;

            write(value);
            let installed = read();
            this.entries.push({
                target, key, kind,
                apply: (next: T) =>
                {
                    if (!same(read(), next))
                        write(next);

                    installed = read();
                },
                restore: () =>
                {
                    if (!same(read(), installed))
                        return false;

                    write(original);
                    return true;
                },
            });
        }
        catch (error)
        {
            this.fail(error);
            throw error;
        }
    }

    private fail(error: unknown): void
    {
        this.state = "failed";
        this.errors.push(error instanceof Error ? error.message : String(error));
    }

    wrap(object: object, name: PropertyKey, wrapper: Function): void
    {
        this.set(object, name, wrapper);
    }

    set(object: object, name: PropertyKey, value: unknown): void
    {
        const descriptor = Object.getOwnPropertyDescriptor(object, name);
        this.change(object, name, "descriptor", {
            configurable: true, enumerable: descriptor?.enumerable ?? false, writable: true, value,
        } as PropertyDescriptor | undefined, () => Object.getOwnPropertyDescriptor(object, name), (next) =>
        {
            if (next)
                Object.defineProperty(object, name, next);
            else if (!Reflect.deleteProperty(object, name))
                throw new Error(`Cannot remove native property ${String(name)}.`);
        }, sameDescriptor);
    }

    style(element: HTMLElement | SVGElement, property: string, value: string, priority = ""): void
    {
        const style = element.style;
        this.change(style, property, "style", { value, priority }, () => ({
            value: style.getPropertyValue(property), priority: style.getPropertyPriority(property),
        }), (next) =>
        {
            if (next.value)
                style.setProperty(property, next.value, next.priority);
            else
                style.removeProperty(property);
        }, (left, right) => left.value === right.value && left.priority === right.priority);
    }

    attribute(element: Element, name: string, value: string | null): void
    {
        this.change(element, name, "attribute", value, () => element.getAttribute(name), (next) =>
        {
            if (next === null)
                element.removeAttribute(name);
            else
                element.setAttribute(name, next);
        });
    }

    map<K, V>(map: Map<K, V>, key: K, value: V): void
    {
        this.change(map, key, "map", { has: true, value }, () => ({ has: map.has(key), value: map.get(key) }), (next) =>
        {
            if (next.has)
                map.set(key, next.value as V);
            else
                map.delete(key);
        }, (left, right) => left.has === right.has && Object.is(left.value, right.value));
    }

    cleanup(callback: () => boolean | void): void
    {
        if (this.restored)
            throw new Error(`The ${this.name} patches are restored.`);

        this.entries.push({ restore: callback });
    }

    own(child: Patches): void
    {
        this.cleanup(() =>
        {
            child.restore();
            const status = child.status();
            if (status.state === "failed")
            {
                const message = `${status.name}: ${status.errors?.join("; ") || "patch restoration failed"}`;
                throw new Error(message.replace(/[\r\n]+/g, " ").slice(0, 2000));
            }

            return status.state !== "skipped";
        });
    }

    restore(): void
    {
        if (this.restored)
            return;

        this.restored = true;
        let skipped = false;
        for (let index = this.entries.length - 1; index >= 0; index--)
        {
            try
            {
                skipped = this.entries[index]!.restore() === false || skipped;
            }
            catch (error)
            {
                this.fail(error);
            }
        }

        if (this.state !== "failed")
            this.state = skipped ? "skipped" : "restored";

        this.report?.(this.status());
    }

    status(): PatchStatus
    {
        const ret: PatchStatus = { name: this.name, state: this.state };
        if (this.errors.length)
            ret.errors = [...this.errors];

        return ret;
    }
}

/** Aggregates transient children without retaining detached native elements. */
export function restorePatches(children: Iterable<Patches>): boolean
{
    const errors: string[] = [];
    let restored = true;
    for (const child of children)
    {
        child.restore();
        const status = child.status();
        if (status.state === "failed")
            errors.push(status.name);
        if (status.state === "skipped")
            restored = false;
    }
    if (errors.length)
        throw new Error(`Patch restoration failed: ${errors.slice(0, 8).join(", ")}.`);
    return restored;
}
