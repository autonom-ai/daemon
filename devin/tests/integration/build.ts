import { verifyDesktopBuild } from "../../launcher/desktop/build";

import assert from "node:assert/strict";
import { test } from "node:test";

const realAppRoot = process.env.AUTONOM_TEST_DESKTOP_APP || "/usr/share/devin-desktop/resources/app";

test("the installed Desktop build satisfies the pin or its owning package", async () =>
{
    const identity = await verifyDesktopBuild(realAppRoot);
    assert.ok(identity.source === "pin" || identity.source === "package");
});
