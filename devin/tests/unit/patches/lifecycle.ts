import { Patches, type PatchStatus } from "../../../launcher/patches/lifecycle";

import assert from "node:assert/strict";
import { test } from "node:test";

test("patches restore exact own descriptors without evaluating accessors", () =>
{
    let calls = 0;
    const object = {};
    const original = {
        configurable: true,
        enumerable: false,
        get: () => { calls++; return "native"; },
        set: () => { calls++; },
    };
    Object.defineProperty(object, "method", original);
    const patches = new Patches("manifest");
    const wrapper = () => "custom";
    patches.wrap(object, "method", wrapper);
    assert.equal(Object.getOwnPropertyDescriptor(object, "method")?.value, wrapper);
    patches.restore();
    assert.deepEqual(Object.getOwnPropertyDescriptor(object, "method"), original);
    assert.equal(calls, 0);
    assert.deepEqual(patches.status(), { name: "manifest", state: "restored" });
});

test("patches remove shadows of inherited properties and properties that were absent", () =>
{
    const prototype = { method: () => "native" };
    const object = Object.create(prototype);
    const symbol = Symbol("native state");
    const patches = new Patches();
    patches.wrap(object, "method", () => "custom");
    patches.set(object, symbol, undefined);
    assert.equal(Object.hasOwn(object, "method"), true);
    assert.equal(Object.hasOwn(object, symbol), true);
    patches.restore();
    assert.equal(Object.hasOwn(object, "method"), false);
    assert.equal(Object.hasOwn(object, symbol), false);
    assert.equal(object.method, prototype.method);
});

test("repeated updates to a property retain its first descriptor", () =>
{
    const object = {};
    Object.defineProperty(object, "value", { configurable: true, enumerable: true, writable: false, value: "native" });
    const original = Object.getOwnPropertyDescriptor(object, "value");
    const patches = new Patches();
    patches.set(object, "value", "first");
    patches.set(object, "value", "second");
    assert.equal(Object.getOwnPropertyDescriptor(object, "value")?.value, "second");
    patches.restore();
    assert.deepEqual(Object.getOwnPropertyDescriptor(object, "value"), original);
});

test("a foreign descriptor replacement is left untouched without invoking its getter", () =>
{
    const object = { value: "native" };
    const patches = new Patches();
    patches.set(object, "value", "custom");
    let calls = 0;
    const foreign = { configurable: true, enumerable: true, get: () => { calls++; return "custom"; } };
    Object.defineProperty(object, "value", foreign);
    const expected = Object.getOwnPropertyDescriptor(object, "value");
    patches.restore();
    assert.deepEqual(Object.getOwnPropertyDescriptor(object, "value"), expected);
    assert.equal(calls, 0);
    assert.equal(patches.status().state, "skipped");
});

test("descriptor ownership includes flags even when the value is unchanged", () =>
{
    const object = { value: "native" };
    const patches = new Patches();
    patches.set(object, "value", "custom");
    Object.defineProperty(object, "value", { enumerable: false });
    patches.restore();
    assert.equal(object.value, "custom");
    assert.equal(Object.getOwnPropertyDescriptor(object, "value")?.enumerable, false);
    assert.equal(patches.status().state, "skipped");
});

test("repeated identical property updates do not redefine the installed descriptor", () =>
{
    let definitions = 0;
    const object = new Proxy({ value: "native" }, {
        defineProperty(target, name, descriptor)
        {
            definitions++;
            return Reflect.defineProperty(target, name, descriptor);
        },
    });
    const patches = new Patches();
    patches.set(object, "value", "native");
    assert.equal(definitions, 0);
    patches.set(object, "value", "custom");
    patches.set(object, "value", "custom");
    assert.equal(definitions, 1);
    patches.restore();
    assert.equal(definitions, 2);
});

test("map restoration distinguishes absent keys, present undefined, and owned objects", () =>
{
    const native = { stack: ["/native"] };
    const custom = { stack: ["/custom"] };
    const map = new Map<string, unknown>([["undefined", undefined], ["existing", native]]);
    const patches = new Patches();
    patches.map(map, "absent", custom);
    patches.map(map, "undefined", custom);
    patches.map(map, "existing", custom);
    patches.restore();
    assert.equal(map.has("absent"), false);
    assert.equal(map.has("undefined"), true);
    assert.equal(map.get("undefined"), undefined);
    assert.equal(map.get("existing"), native);
});

test("repeated map updates retain the first entry including NaN and zero keys", () =>
{
    const map = new Map<number, string>([[NaN, "native"], [0, "zero"]]);
    const patches = new Patches();
    patches.map(map, NaN, "first");
    patches.map(map, NaN, "second");
    patches.map(map, -0, "first");
    patches.map(map, 0, "second");
    patches.restore();
    assert.equal(map.get(NaN), "native");
    assert.equal(map.get(0), "zero");
    assert.equal(patches.status().state, "restored");
});

test("foreign map replacement and deletion survive restoration", () =>
{
    const map = new Map([["changed", "native"], ["deleted", "native"]]);
    const patches = new Patches();
    patches.map(map, "changed", "custom");
    patches.map(map, "deleted", "custom");
    map.set("changed", "foreign");
    map.delete("deleted");
    patches.restore();
    assert.equal(map.get("changed"), "foreign");
    assert.equal(map.has("deleted"), false);
    assert.equal(patches.status().state, "skipped");
});

test("cleanup runs in reverse order once and isolates failures", () =>
{
    const calls: string[] = [];
    const reports: PatchStatus[] = [];
    const object = { value: "native" };
    const patches = new Patches("window", (status) => reports.push(status));
    patches.cleanup(() => { calls.push(`first:${object.value}`); });
    patches.set(object, "value", "custom");
    patches.cleanup(() =>
    {
        calls.push("failing");
        throw new Error("native disposal failed");
    });
    patches.cleanup(() => { calls.push(`last:${object.value}`); });
    patches.restore();
    patches.restore();
    assert.deepEqual(calls, ["last:custom", "failing", "first:native"]);
    assert.equal(object.value, "native");
    assert.deepEqual(reports, [{ name: "window", state: "failed", errors: ["native disposal failed"] }]);
});

test("an unsuccessful installation leaves no unapplied restoration record", () =>
{
    const object = { working: "native" };
    Object.defineProperty(object, "locked", { value: "locked", configurable: false });
    const locked = Object.getOwnPropertyDescriptor(object, "locked");
    const patches = new Patches();
    patches.set(object, "working", "custom");
    assert.throws(() => patches.set(object, "locked", "custom"), TypeError);
    patches.restore();
    assert.equal(object.working, "native");
    assert.deepEqual(Object.getOwnPropertyDescriptor(object, "locked"), locked);
    assert.equal(patches.status().state, "failed");
    assert.equal(patches.status().errors?.length, 1);
});

test("a failed descriptor restoration does not prevent other native restoration", () =>
{
    const working = { value: "native" };
    let reject = false;
    const failing = new Proxy({ value: "native" }, {
        defineProperty(target, name, descriptor)
        {
            if (reject)
                throw new Error("restoration refused");

            return Reflect.defineProperty(target, name, descriptor);
        },
    });
    const patches = new Patches();
    patches.set(working, "value", "custom");
    patches.set(failing, "value", "custom");
    reject = true;
    patches.cleanup(() =>
    {
        throw new Error("another cleanup failed");
    });
    patches.restore();
    assert.equal(working.value, "native");
    assert.equal(failing.value, "custom");
    assert.equal(patches.status().state, "failed");
    assert.equal(patches.status().errors?.length, 2);
});

test("a failed repeated update preserves the last successfully owned descriptor", () =>
{
    const target = { value: "native" };
    let reject = false;
    const object = new Proxy(target, {
        defineProperty(target, name, descriptor)
        {
            if (reject)
                throw new Error("definition refused");

            return Reflect.defineProperty(target, name, descriptor);
        },
    });
    const patches = new Patches();
    patches.set(object, "value", "first");
    reject = true;
    assert.throws(() => patches.set(object, "value", "second"), /definition refused/);
    reject = false;
    patches.restore();
    assert.equal(object.value, "native");
    assert.equal(patches.status().errors?.length, 1);
});

test("restored owners reject new changes and status returns independent error arrays", () =>
{
    const patches = new Patches();
    patches.cleanup(() => { throw new Error("failure"); });
    patches.restore();
    patches.status().errors?.push("external");
    assert.deepEqual(patches.status().errors, ["failure"]);
    assert.throws(() => patches.set({}, "value", true), /patches are restored/);
    assert.throws(() => patches.cleanup(() => undefined), /patches are restored/);
});

test("own restores children in reverse order and propagates skipped ownership", () =>
{
    const object = { value: "native" };
    const child = new Patches("child");
    child.set(object, "value", "custom");
    object.value = "foreign";
    const parent = new Patches("parent");
    const order: string[] = [];
    parent.cleanup(() => { order.push("first"); });
    parent.own(child);
    parent.cleanup(() => { order.push("last"); });
    parent.restore();
    parent.restore();
    assert.deepEqual(order, ["last", "first"]);
    assert.equal(object.value, "foreign");
    assert.equal(child.status().state, "skipped");
    assert.deepEqual(parent.status(), { name: "parent", state: "skipped" });
});

test("own propagates sanitized child errors while restoring remaining children", () =>
{
    const failed = new Patches("child");
    failed.cleanup(() => { throw new Error("disposal\nfailed"); });
    const object = { value: "native" };
    const working = new Patches("working");
    working.set(object, "value", "custom");
    const parent = new Patches("parent");
    parent.own(working);
    parent.own(failed);
    parent.restore();
    assert.equal(object.value, "native");
    assert.equal(working.status().state, "restored");
    assert.equal(failed.status().state, "failed");
    assert.deepEqual(parent.status(), { name: "parent", state: "failed", errors: ["child: disposal failed"] });
});

test("cleanup preserves explicit skipped results and restored parents reject children", () =>
{
    const parent = new Patches();
    parent.cleanup(() => false);
    parent.restore();
    assert.equal(parent.status().state, "skipped");
    assert.throws(() => parent.own(new Patches()), /patches are restored/);
});
