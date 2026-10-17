type Options = {
    arguments: string[];
    debugPort: number | undefined;
};

export function parseArguments(argv: string[]): Options
{
    const ret: Options = { arguments: [], debugPort: undefined };
    for (const argument of argv)
    {
        if (argument === "--debug")
            ret.debugPort = 9222;
        else if (argument.startsWith("--debug="))
            ret.debugPort = port(argument.slice("--debug=".length));
        else
            ret.arguments.push(argument);
    }

    return ret;
}

function port(value: string): number
{
    const ret = Number(value);
    if (!Number.isInteger(ret) || ret < 1 || ret > 65535)
        throw new Error("The port must be an integer between 1 and 65535.");

    return ret;
}

export function environmentPort(): number | undefined
{
    const value = process.env.AUTONOM_PORT;
    return value?.trim() ? port(value) : undefined;
}
