module autonom.config;

import autonom.storage : openFile;
import dyaml : Loader, Node, NodeType;

import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : canFind;
import std.exception : enforce;
import std.file : exists;
import std.json : JSONValue;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, expandTilde;
import std.process : environment;
import std.stdio : File;

class Config
{
public:
    const string path;
    const string dataDir;
    const string sessionLockDir;
    const string devinCommand;

    static string defaultPath()
        => buildPath(environment.get("XDG_CONFIG_HOME", expandTilde("~/.config")), "autonom", "config.yml");

    static string defaultSessionLockDir()
        => buildPath(
            environment.get("XDG_DATA_HOME", expandTilde("~/.local/share")),
            "devin",
            "cli",
            "session_locks"
        );

    this(string path = defaultPath)
    {
        this.path = buildNormalizedPath(absolutePath(expandTilde(path)));
        string data = dirName(this.path);
        string locks = defaultSessionLockDir;
        string command = "devin";
        if (exists(this.path))
        {
            File file = openFile(this.path, O_RDONLY);
            scope(exit)
                file.close();

            Node settings = Loader.fromFile(file).load();
            enforce(settings.type == NodeType.mapping, "Configuration must be a YAML mapping");
            foreach (Node key, Node value; settings)
            {
                enforce(key.type == NodeType.string && value.type == NodeType.string,
                    "Configuration settings must be strings");
                string setting = value.get!string;
                enforce(setting.length && !setting.canFind('\0'), "Configuration settings must not be empty");
                switch (key.get!string)
                {
                    case "dataDir":
                        data = setting;
                        break;
                    case "sessionLockDir":
                        locks = setting;
                        break;
                    case "devinCommand":
                        command = setting;
                        break;
                    default:
                        throw new Exception("Unknown configuration setting");
                }
            }
        }

        dataDir = buildNormalizedPath(absolutePath(expandTilde(data), dirName(this.path)));
        sessionLockDir = buildNormalizedPath(absolutePath(expandTilde(locks), dirName(this.path)));
        devinCommand = command.canFind('/') ?
            buildNormalizedPath(absolutePath(expandTilde(command), dirName(this.path))) : command;
    }

    JSONValue toJSON() const
    {
        return JSONValue([
            "dataDir": JSONValue(dataDir),
            "sessionLockDir": JSONValue(sessionLockDir),
            "devinCommand": JSONValue(devinCommand)
        ]);
    }
}
