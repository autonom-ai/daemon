/** Restores exact native descriptors only while our wrapper is still installed. */
export class Patches
{
    private readonly descriptors: {
        object: any;
        name: string;
        descriptor: PropertyDescriptor | undefined;
        wrapper: Function;
    }[] = [];

    wrap(object: any, name: string, wrapper: Function): void
    {
        this.descriptors.push({ object, name, descriptor: Object.getOwnPropertyDescriptor(object, name), wrapper });
        Object.defineProperty(object, name, { configurable: true, writable: true, value: wrapper });
    }

    restore(): void
    {
        for (const saved of this.descriptors.reverse())
        {
            if (saved.object[saved.name] !== saved.wrapper)
                continue;

            if (saved.descriptor)
                Object.defineProperty(saved.object, saved.name, saved.descriptor);
            else
                delete saved.object[saved.name];
        }
    }
}
