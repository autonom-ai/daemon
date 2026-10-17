import { main } from "./build";

main().then((code) =>
{
    process.exitCode = code;
}, (error: unknown) =>
{
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
});
