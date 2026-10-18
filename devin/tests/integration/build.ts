import { installerStatus } from "../../launcher/patches/installer";
import { verifyDesktopBuild } from "../../launcher/desktop/build";

import assert from "node:assert/strict";
import { resolve } from "node:path";
import { test } from "node:test";

const realAppRoot = process.env.AUTONOM_TEST_DESKTOP_APP || "/usr/share/devin-desktop/resources/app";

test("the installed Desktop build satisfies the pin or its owning package", async () =>
{
    const identity = await verifyDesktopBuild(realAppRoot);
    assert.ok(identity.source === "pin" || identity.source === "package");
});

test("the installed launcher reports verified shim and backup provenance", async () =>
{
    const identity = await verifyDesktopBuild(realAppRoot);
    const status = await installerStatus(resolve(realAppRoot, "../../autonom"), realAppRoot, identity);
    assert.equal(status.state, "installed", JSON.stringify(status));
});
