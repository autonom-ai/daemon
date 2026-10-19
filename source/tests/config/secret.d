module tests.config.secret;

import daemon.config;

import intuit.router.openrouter;
import unit_threaded : Name, should, shouldThrow;

import std.algorithm.searching : canFind;
import std.file : exists, readText, remove, symlink, write;
import std.path : buildPath;
import tests.common;

/// A credential file exercising every form the parser accepts, plus entries it
/// must ignore.
private enum dotEnv =
    "# router credentials\r\n"~
    "\r\n"~
    "export OPENROUTER_API_KEY=sk-or-v1-actual\r\n"~
    "QUOTED=\"quoted-value\"\r\n"~
    "SINGLE='single-value'\r\n"~
    "WITH_EQUALS=abc=def==\r\n"~
    "  SPACED  =  padded  \r\n"~
    "EMPTY=\r\n"~
    "NO_EQUALS\r\n";

private string dotEnvPath(Fixture fixture)
    => buildPath(fixture.root, ".env");

private void writeDotEnv(Fixture fixture)
    => write(dotEnvPath(fixture), dotEnv);

private void writeReferencedRouter(Fixture fixture)
{
    write(fixture.path, "devinCommand: devin\nrouter:\n  type: openrouter\n  key: OPENROUTER_API_KEY\n"~
        "  url: https://router.example\n  name: autonom-test\n");
}

// Tests own a fresh fixture per case and drop the credential file beside it, so
// each case states the .env it needs rather than sharing one setup.
@Name("Secret resolves an uppercase reference from the .env beside the configuration")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    resolveSecret("OPENROUTER_API_KEY", fixture.root).should == "sk-or-v1-actual";
    resolveSecret("QUOTED", fixture.root).should == "quoted-value";
    resolveSecret("SINGLE", fixture.root).should == "single-value";
    resolveSecret("WITH_EQUALS", fixture.root).should == "abc=def==";
    resolveSecret("SPACED", fixture.root).should == "padded";
}

@Name("Secret leaves a literal credential untouched")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    foreach (literal; ["test-key", "sk-or-v1-abc123", "ABC-def-123", "Lower_Case", ""])
        resolveSecret(literal, fixture.root).should == literal;
}

@Name("Secret ignores .env entries that are not assignments")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    // A line with no '=' and one with an empty value both leave the reference
    // undefined rather than resolving to something usable.
    foreach (ignored; ["NO_EQUALS", "EMPTY"])
        resolveSecret(ignored, fixture.root).shouldThrow!Exception();
}

@Name("Secret refuses a reference no .env defines")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    resolveSecret("ABSENT_API_KEY", fixture.root).shouldThrow!Exception();
}

@Name("Secret reports a missing .env without inventing a credential")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    exists(dotEnvPath(fixture)).should == false;
    resolveSecret("OPENROUTER_API_KEY", fixture.root).shouldThrow!Exception();
}

@Name("Secret refuses a symlinked .env")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    // The storage guards that protect the configuration file protect this too.
    symlink(fixture.path, dotEnvPath(fixture));
    resolveSecret("OPENROUTER_API_KEY", fixture.root).shouldThrow!Exception();
}

@Name("Secret refuses an oversized .env")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    write(dotEnvPath(fixture), "OPENROUTER_API_KEY="~new char[64 * 1024]~"\n");
    resolveSecret("OPENROUTER_API_KEY", fixture.root).shouldThrow!Exception();
}

@Name("Secret names the variable and the file without leaking a credential")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    string secret = resolveSecret("OPENROUTER_API_KEY", fixture.root);
    secret.should == "sk-or-v1-actual";

    // Point the reference at a name the file does not define, so the failure
    // message is produced while a real credential is present in the same file.
    remove(dotEnvPath(fixture));
    try
        resolveSecret("ABSENT_API_KEY", fixture.root);
    catch (Exception error)
    {
        error.msg.canFind("ABSENT_API_KEY").should == true;
        error.msg.canFind(dotEnvPath(fixture)).should == true;
        error.msg.canFind(secret).should == false;
        return;
    }

    assert(false, "An absent reference must not resolve");
}

@Name("Config builds its router from a credential reference and keeps the secret out of the file")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeDotEnv(fixture);

    write(fixture.path, "devinCommand: devin\nrouter:\n  type: openrouter\n  key: OPENROUTER_API_KEY\n"~
        "  url: https://router.example\n  name: autonom-test\n  referer: https://example.test\n"~
        "  title: Autonom Test\n");
    OpenRouter router = cast(OpenRouter)new Config(fixture.path).router;
    (router !is null).should == true;
    router.name.should == "autonom-test";
    router.referer.should == "https://example.test";
    router.title.should == "Autonom Test";

    string content = readText(fixture.path);
    content.canFind("OPENROUTER_API_KEY").should == true;
    content.canFind("sk-or-v1-actual").should == false;
}

@Name("Config keeps a literal router key working")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (literal; ["test-key", "sk-or-v1-abc123", "ABC-def-123", "Lower_Case"])
    {
        write(fixture.path, "devinCommand: devin\nrouter:\n  type: openrouter\n  key: "~literal~
            "\n  url: https://router.example\n  name: autonom-test\n");
        (new Config(fixture.path).router is null).should == false;
    }
}

@Name("Config refuses a router key reference no .env defines")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    writeReferencedRouter(fixture);

    (new Config(fixture.path)).shouldThrow!Exception();
}