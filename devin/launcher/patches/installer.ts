import type { BuildIdentity } from "../desktop/build";
import { object } from "../parse";
import { readPrivateFile } from "../storage";

import { createHash } from "node:crypto";
import { join } from "node:path";

/** Observes installer provenance; the launcher never applies this disk patch. */
export async function installerStatus(repository: string, appRoot: string, build: BuildIdentity)
{
    const hook = "bin/devin-desktop";
    try
    {
        const record = object(JSON.parse(await readPrivateFile(join(repository, "install.json"))));
        const cli = object(record?.cli);
        const identity = object(record?.build);
        if (record?.version !== 2 || typeof cli?.stubHash !== "string"
            || typeof cli.originalHash !== "string" || typeof cli.backupPath !== "string"
            || identity?.version !== build.version || identity.commit !== build.commit)
            throw new Error("Installation record does not match the verified Desktop build.");
        const digest = (source: string) => createHash("sha256").update(source).digest("hex");
        const current = digest(await readPrivateFile(join(appRoot, "..", "..", hook), 1048576));
        const backup = digest(await readPrivateFile(cli.backupPath, 1048576));
        if (current !== cli.stubHash || backup !== cli.originalHash)
            throw new Error("CLI shim or its recorded backup differs from installation provenance.");
        return { name: "installer.cli-shim", hook, state: "installed", build: build.version };
    }
    catch (error)
    {
        return { name: "installer.cli-shim", hook, state: "skipped",
            errors: [error instanceof Error ? error.message : String(error)] };
    }
}
