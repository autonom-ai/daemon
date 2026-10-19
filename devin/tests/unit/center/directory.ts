import { Directory } from "../../../launcher/center/directory";

import assert from "node:assert/strict";
import { test } from "node:test";

test("listings carry the section mark and leave profiles for their identicons", async () =>
{
    const directory = new Directory(async (message) =>
    {
        if (message.action === "getRooms")
            return [{ name: "ops" }, { name: "ada" }];
        return [{ name: "Grace" }];
    }, () => { });
    try
    {
        directory.refresh();
        await new Promise((resolve) => setImmediate(resolve));
        assert.deepEqual(directory.entries("rooms"), [
            { name: "ada", icon: "hash" },
            { name: "ops", icon: "hash" },
        ]);
        assert.deepEqual(directory.entries("profiles"), [{ name: "Grace" }]);
    }
    finally
    {
        directory.dispose();
    }
});
