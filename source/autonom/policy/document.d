module autonom.policy.document;

import autonom.policy.rule : PolicyRule;
import autonom.storage : openFile;
import mir.deser.yaml : deserializeYaml;

import core.sys.posix.fcntl : O_RDONLY;
import std.array : join;
import std.exception : enforce;
import std.path : buildPath;
import std.stdio : File;

public:

struct PolicyDocument
{
    PolicyRule[] rules;

    static PolicyDocument load(string directory)
    {
        enum MAX_SIZE = 64 * 1024;
        File file = openFile(buildPath(directory, ".devin", "policy.yml"), O_RDONLY);
        scope(exit)
            file.close();

        enforce(file.size <= MAX_SIZE, "Workspace policy is too large");
        string content = cast(string)file.byChunk(4096).join;
        enforce(content.length <= MAX_SIZE, "Workspace policy is too large");
        PolicyDocument ret = deserializeYaml!PolicyDocument(content);
        foreach (ref rule; ret.rules)
            rule.compile();

        return ret;
    }
}
