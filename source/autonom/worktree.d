module autonom.worktree;

import autonom.agent;
import autonom.config;
import autonom.coord;
import autonom.events.event : Event, EventType;
import autonom.exception;
import autonom.interop.execution : childEnvironment, signalExecution;
import autonom.server;
import autonom.storage;
import serverino;

import core.sync.mutex;
import core.thread : Thread;
import core.time : Duration, minutes, msecs, seconds;
import std.algorithm : map, sort;
import std.array : array, join;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.datetime : Clock, UTC;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.process : Pid, spawnProcess, tryWait, wait;
import std.process : ProcessConfig = Config;
import std.stdio : File;
import std.string : lineSplitter, strip, startsWith;
import std.typecons : Nullable;
private:

enum REGISTRY_FILE = "worktrees.json";
enum MERGES_FILE = "merges.json";
enum WORKTREES_DIR = ".autonom-worktrees";
enum BRANCH_PREFIX = "autonom/";
enum MAX_WORKTREES = 64;
enum GIT_TIMEOUT = 2.minutes;
enum MAX_OUTPUT = 1024 * 1024;

string git(string[] arguments, string directory)
{
    File output = File.tmpfile();
    File errors = File.tmpfile();
    scope(exit)
    {
        output.close();
        errors.close();
    }

    Pid process = spawnProcess(
        ["git"]~arguments,
        File("/dev/null", "r"),
        output,
        errors,
        childEnvironment(),
        ProcessConfig.retainStdout | ProcessConfig.retainStderr,
        directory
    );
    bool finished;
    scope(failure)
    {
        if (!finished)
        {
            signalExecution(process, 9);
            wait(process);
        }
    }

    auto deadline = Clock.currTime + GIT_TIMEOUT;
    typeof(tryWait(Pid.init)) result;
    while (!(result = tryWait(process)).terminated)
    {
        if (Clock.currTime >= deadline)
            throw new BackendException("git timed out");

        Thread.sleep(10.msecs);
    }

    finished = true;
    output.rewind();
    errors.rewind();
    string text = cast(string)output.byChunk(4096).join;
    if (text.length > MAX_OUTPUT)
        throw new Exception("git output is too large");

    if (result.status != 0)
    {
        string detail = strip(cast(string)errors.byChunk(4096).join);
        if (!detail.length)
            detail = strip(cast(string)output.byChunk(4096).join);

        throw new BackendException(detail.length ? detail : "git failed (exit "~result.status.to!string~")");
    }

    return text;
}

JSONValue emptyObject()
{
    return parseJSON("{}");
}

JSONValue stringArray(const(string)[] values)
{
    JSONValue ret = parseJSON("[]");
    foreach (value; values)
        ret.array ~= JSONValue(value);

    return ret;
}

bool validName(string name)
{
    if (!name.length || name.length > 64 || !isAlphaNum(name[0]))
        return false;

    foreach (character; name)
    {
        if (!isAlphaNum(character) && character != '-' && character != '_')
            return false;
    }

    return true;
}

bool clean(string path)
{
    string status = git(["status", "--porcelain"], path);
    return !status.strip.length;
}

string[] unmerged(string path)
{
    string[] ret;
    foreach (line; git(["diff", "--name-only", "--diff-filter=U"], path).lineSplitter)
    {
        if (line.strip.length)
            ret ~= line.strip;
    }

    return ret;
}

string timestamp()
{
    return Clock.currTime(UTC()).toISOExtString();
}

struct Worktree
{
    string name;
    string path;
    string branch;
    string created;

    static Worktree create(string name, string path, string branch)
    {
        Worktree ret;
        ret.name = name.idup;
        ret.path = path.idup;
        ret.branch = branch.idup;
        ret.created = timestamp();
        return ret;
    }

    JSONValue toJSON() const
    {
        JSONValue ret = emptyObject();
        ret["name"] = JSONValue(name);
        ret["path"] = JSONValue(path);
        ret["branch"] = JSONValue(branch);
        ret["created"] = JSONValue(created);
        return ret;
    }

    static bool parse(JSONValue data, out Worktree worktree)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["name", "path", "branch", "created"])
        {
            if (field !in data.object || data[field].type != JSONType.string)
                return false;
        }

        worktree.name = data["name"].str.idup;
        worktree.path = data["path"].str.idup;
        worktree.branch = data["branch"].str.idup;
        worktree.created = data["created"].str.idup;
        return true;
    }
}

struct Merge
{
    string id;
    string target;
    string source;
    string room;
    string[] files;
    string created;

    JSONValue toJSON() const
    {
        JSONValue ret = emptyObject();
        ret["id"] = JSONValue(id);
        ret["target"] = JSONValue(target);
        ret["source"] = JSONValue(source);
        ret["room"] = JSONValue(room);
        ret["files"] = stringArray(files);
        ret["created"] = JSONValue(created);
        return ret;
    }

    static bool parse(JSONValue data, out Merge merge)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["id", "target", "source", "room", "created"])
        {
            if (field !in data.object || data[field].type != JSONType.string)
                return false;
        }

        if ("files" !in data.object || data["files"].type != JSONType.array)
            return false;

        merge.id = data["id"].str.idup;
        merge.target = data["target"].str.idup;
        merge.source = data["source"].str.idup;
        merge.room = data["room"].str.idup;
        merge.created = data["created"].str.idup;
        foreach (file; data["files"].array)
        {
            if (file.type != JSONType.string)
                return false;

            merge.files ~= file.str.idup;
        }

        return true;
    }
}

string worktreeConflictMessage(Merge merge, string[] files, string summary)
{
    string ret = "Merge conflict: "~merge.source~" into "~merge.target~" (room #"~merge.room~").";
    if (files.length)
        ret ~= " Conflicted files: "~files.join(", ")~".";
    if (summary.length)
        ret ~= " "~summary;

    return ret;
}

public:

class WorktreeManager
{
private:
    const string repository;
    const string directory;
    const string registryPath;
    const string mergesPath;
    Mutex mutex;
    Worktree[string] worktrees;
    Merge[string] merges;

    void loadWorktrees()
    {
        if (!exists(registryPath))
            return;

        JSONValue data = readJSON(registryPath);
        if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
            "worktrees" !in data.object || data["worktrees"].type != JSONType.array)
            throw new Exception("Invalid worktree registry");

        foreach (entry; data["worktrees"].array)
        {
            Worktree worktree;
            if (!Worktree.parse(entry, worktree))
                throw new Exception("Invalid worktree record");

            worktrees[worktree.name] = worktree;
        }
    }

    void saveWorktrees()
    {
        JSONValue data = emptyObject();
        data["version"] = JSONValue(1);
        data["worktrees"] = parseJSON("[]");
        Worktree[] sorted = list();
        foreach (worktree; sorted)
            data["worktrees"].array ~= worktree.toJSON();

        atomicWrite(registryPath, data.toString());
    }

    void loadMerges()
    {
        if (!exists(mergesPath))
            return;

        JSONValue data = readJSON(mergesPath);
        if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
            "merges" !in data.object || data["merges"].type != JSONType.array)
            throw new Exception("Invalid merge registry");

        foreach (entry; data["merges"].array)
        {
            Merge merge;
            if (!Merge.parse(entry, merge))
                throw new Exception("Invalid merge record");

            merges[merge.id] = merge;
        }
    }

    void saveMerges()
    {
        JSONValue data = emptyObject();
        data["version"] = JSONValue(1);
        data["merges"] = parseJSON("[]");
        Merge[] sorted;
        foreach (_, merge; merges)
            sorted ~= merge;

        sorted.sort!((left, right) => left.created < right.created);
        foreach (merge; sorted)
            data["merges"].array ~= merge.toJSON();

        atomicWrite(mergesPath, data.toString());
    }

    Merge* active(string name)
    {
        foreach (ref merge; merges)
        {
            if (merge.target == name || merge.source == name)
                return &merge;
        }

        return null;
    }

    void ignoreWorktrees()
    {
        string path = buildPath(repository, ".gitignore");
        string content = exists(path) ? readText(path, 1024 * 1024) : "";
        foreach (line; content.lineSplitter)
        {
            if (line.strip == WORKTREES_DIR~"/" || line.strip == WORKTREES_DIR)
                return;
        }

        if (content.length && content[$ - 1] != '\n')
            content ~= "\n";

        write(path, content~WORKTREES_DIR~"/\n");
    }

    Room conflictRoom(Merge merge, Profile[] members, Profile human)
    {
        Room room = bus.getRoom(merge.room);
        if (room is null)
        {
            room = bus.createRoom(merge.room, human.name);
            string[] involved;
            foreach (member; members)
            {
                if (member.name != human.name)
                    involved ~= member.name;
            }

            room.setInvolved(involved);
            foreach (name; involved)
                room.addAdmin(name);
        }

        return room;
    }

    void surface(Profile[] members, Merge merge, string[] files, string summary)
    {
        string text = worktreeConflictMessage(merge, files, summary);
        foreach (member; members)
            events.surface(member, Event.create(EventType.Room, "", HUMAN_NAME, text, merge.room));
    }

    Merge record(string target, string source, string room, string[] files)
    {
        Merge merge;
        merge.id = target~":"~source;
        merge.target = target.idup;
        merge.source = source.idup;
        merge.room = room.idup;
        merge.files = files.dup;
        merge.created = timestamp();
        merges[merge.id] = merge;
        saveMerges();
        return merge;
    }

    void close(Merge merge)
    {
        Room room = bus.getRoom(merge.room);
        if (room !is null)
            bus.deleteRoom(room);

        merges.remove(merge.id);
        saveMerges();
    }

public:
    this(Config configuration)
    {
        repository = configuration.repository;
        directory = configuration.dataDir;
        registryPath = buildPath(directory, REGISTRY_FILE);
        mergesPath = buildPath(directory, MERGES_FILE);
        mutex = new Mutex();
        synchronized (mutex)
        {
            loadWorktrees();
            loadMerges();
        }
    }

    string base()
        => repository;

    Worktree[] list()
    {
        Worktree[] ret;
        foreach (_, worktree; worktrees)
            ret ~= worktree;

        ret.sort!((left, right) => left.name < right.name);
        return ret;
    }

    Nullable!Worktree get(string name)
    {
        Worktree* found = name in worktrees;
        return found is null ? Nullable!Worktree.init : Nullable!Worktree(*found);
    }

    string status(string name)
    {
        Worktree* found = name in worktrees;
        if (found is null)
            throw new InvalidInputException("Unknown worktree: "~name);

        if (!exists(found.path))
            return "missing";

        try
        {
            if (!clean(found.path))
                return "dirty";
        }
        catch (Exception)
            return "unknown";
        return "ready";
    }

    Worktree create(string name, string source)
    {
        if (!validName(name))
            throw new InvalidInputException("Invalid worktree name");

        synchronized (mutex)
        {
            if (name in worktrees)
                throw new ConflictException("Worktree already exists: "~name);

            try
                git(["rev-parse", "--git-dir"], repository);
            catch (Exception)
                throw new InvalidInputException("The workspace is not a git repository");

            string path = buildPath(repository, WORKTREES_DIR, name);
            if (exists(path))
                throw new ConflictException("Worktree directory already exists: "~path);

            string branch = BRANCH_PREFIX~name;
            bool branchExists;
            try
            {
                git(["rev-parse", "--verify", branch], repository);
                branchExists = true;
            }
            catch (BackendException)
            {
            }

            if (branchExists)
                throw new ConflictException("Branch already exists: "~branch);

            string[] arguments = ["worktree", "add", "-b", branch, path];
            if (source.length)
                arguments ~= source;

            try
                git(arguments, repository);
            catch (BackendException error)
                throw new InvalidInputException(error.msg);

            ignoreWorktrees();
            Worktree ret = Worktree.create(name, path, branch);
            worktrees[name] = ret;
            saveWorktrees();
            return ret;
        }
    }

    JSONValue remove(string name, bool force)
    {
        synchronized (mutex)
        {
            Worktree* found = name in worktrees;
            if (found is null)
                throw new InvalidInputException("Unknown worktree: "~name);

            if (Merge* merge = active(name))
                throw new ConflictException("Resolve or abort the merge for "~name~" before removing it");

            string[] arguments = ["worktree", "remove"];
            if (force)
                arguments ~= "--force";
            arguments ~= found.path;
            try
                git(arguments, repository);
            catch (BackendException error)
            {
                if (!force)
                    throw error;

                if (exists(found.path))
                    rmdirRecurse(found.path);

                git(["worktree", "prune"], repository);
            }

            try
                git(["branch", "-D", found.branch], repository);
            catch (BackendException)
            {
            }

            JSONValue ret = found.toJSON();
            worktrees.remove(name);
            saveWorktrees();
            return ret;
        }
    }

    JSONValue merge(string target, string source)
    {
        synchronized (mutex)
        {
            Worktree* targetEntry = target in worktrees;
            if (targetEntry is null)
                throw new InvalidInputException("Unknown target worktree: "~target);
            if (source == target)
                throw new InvalidInputException("A worktree cannot merge into itself");
            if (!exists(targetEntry.path))
                throw new ConflictException("Target worktree is missing: "~target);

            Worktree* sourceEntry = source in worktrees;
            if (sourceEntry is null)
                throw new InvalidInputException("Unknown source worktree: "~source);
            if (!exists(sourceEntry.path))
                throw new ConflictException("Source worktree is missing: "~source);

            if (active(target) !is null || active(source) !is null)
                throw new ConflictException("A merge is already in progress for these worktrees");

            if (!clean(targetEntry.path))
                throw new ConflictException("Target worktree has uncommitted changes: "~target);

            string summary;
            try
                summary = git(["merge", "--no-commit", "--no-ff", sourceEntry.branch], targetEntry.path).strip;
            catch (BackendException error)
                summary = error.msg;

            string[] files = unmerged(targetEntry.path);
            if (!files.length)
            {
                git(["merge", "--abort"], targetEntry.path);
                throw new ConflictException("Merge failed without conflicts: "~summary);
            }

            Profile human = profileStore.get(HUMAN_NAME);
            Profile[] members = [human];
            foreach (name; [target, source])
            {
                Profile member = profileStore.get(name);
                if (member is null || member.name == HUMAN_NAME)
                    continue;

                bool seen;
                foreach (existing; members)
                    seen = seen || existing.name == member.name;

                if (!seen)
                    members ~= member;
            }

            Merge merge;
            merge.id = target~":"~source;
            merge.target = target.idup;
            merge.source = source.idup;
            merge.room = "merge-"~target~"-"~source;
            merge.files = files.dup;
            merge.created = timestamp();

            Room room = conflictRoom(merge, members, human);
            merge.room = room.name;
            merges[merge.id] = merge;
            saveMerges();
            surface(members, merge, files, summary);

            JSONValue ret = emptyObject();
            ret["status"] = JSONValue("conflict");
            ret["merge"] = merge.toJSON();
            ret["target"] = JSONValue(target);
            ret["source"] = JSONValue(source);
            ret["files"] = stringArray(files);
            ret["summary"] = JSONValue(summary.length ? summary : null);
            return ret;
        }
    }

    JSONValue mergeAbort(string target, string source)
    {
        synchronized (mutex)
        {
            string id = target~":"~source;
            Merge* found = id in merges;
            if (found is null)
                throw new InvalidInputException("No merge is in progress for "~id);

            Merge merge = *found;
            Worktree* targetEntry = target in worktrees;
            if (targetEntry !is null && exists(targetEntry.path))
                git(["reset", "--merge", "HEAD"], targetEntry.path);

            close(merge);
            JSONValue ret = merge.toJSON();
            ret["status"] = JSONValue("aborted");
            return ret;
        }
    }

    JSONValue mergeFinish(string target, string source)
    {
        synchronized (mutex)
        {
            string id = target~":"~source;
            Merge* found = id in merges;
            if (found is null)
                throw new InvalidInputException("No merge is in progress for "~id);

            Merge merge = *found;
            Worktree* targetEntry = target in worktrees;
            if (targetEntry is null || !exists(targetEntry.path))
                throw new ConflictException("Target worktree is missing: "~target);

            string[] files = unmerged(targetEntry.path);
            if (files.length)
                throw new ConflictException("Conflicts are still unresolved: "~files.join(", "));

            try
                git(["commit", "--no-edit", "--no-verify", "--no-gpg-sign"], targetEntry.path);
            catch (BackendException error)
                throw new ConflictException("Could not commit the resolved merge: "~error.msg);

            close(merge);
            JSONValue ret = merge.toJSON();
            ret["status"] = JSONValue("merged");
            return ret;
        }
    }
}

@endpoint @route!"/api/worktrees"
void worktrees(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue ret = parseJSON("[]");
        foreach (worktree; worktreeManager.list())
        {
            JSONValue record = worktree.toJSON();
            record["status"] = JSONValue(worktreeManager.status(worktree.name));
            ret.array ~= record;
        }

        respond(output, ret);
        return;
    }

    JSONValue data = readBody(request);
    if ("name" !in data.object || data["name"].type != JSONType.string)
        throw new InvalidInputException("A worktree name is required");

    string source;
    if ("source" in data.object)
    {
        if (data["source"].type != JSONType.string)
            throw new InvalidInputException("source must be a git ref");

        source = data["source"].str;
    }

    respond(output, worktreeManager.create(data["name"].str, source).toJSON(), 201);
}

@endpoint @route!(matchesPath!"/api/worktrees/<name>")
void worktree(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Delete]))
        return;

    string name = routeParameter!"/api/worktrees/<name>"(request);
    if (request.method == Request.Method.Get)
    {
        Nullable!Worktree found = worktreeManager.get(name);
        if (found.isNull)
            respond(output, JSONValue(["error": JSONValue("Worktree not found")]), 404);
        else
        {
            JSONValue ret = found.get.toJSON();
            ret["status"] = JSONValue(worktreeManager.status(name));
            respond(output, ret);
        }

        return;
    }

    JSONValue data = readBody(request);
    bool force;
    if ("force" in data.object)
    {
        if (data["force"].type != JSONType.true_ && data["force"].type != JSONType.false_)
            throw new InvalidInputException("force must be true or false");

        force = data["force"].boolean;
    }

    respond(output, worktreeManager.remove(name, force));
}

@endpoint @route!(matchesPath!"/api/worktrees/<name>/merge")
void worktreeMerge(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    string target = routeParameter!"/api/worktrees/<name>/merge"(request);
    JSONValue data = readBody(request);
    if ("source" !in data.object || data["source"].type != JSONType.string)
        throw new InvalidInputException("A source worktree is required");

    respond(output, worktreeManager.merge(target, data["source"].str), 200);
}

@endpoint @route!(matchesPath!"/api/worktrees/<name>/merge/abort")
void worktreeMergeAbort(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    string target = routeParameter!"/api/worktrees/<name>/merge/abort"(request);
    JSONValue data = readBody(request);
    if ("source" !in data.object || data["source"].type != JSONType.string)
        throw new InvalidInputException("A source worktree is required");

    respond(output, worktreeManager.mergeAbort(target, data["source"].str));
}

@endpoint @route!(matchesPath!"/api/worktrees/<name>/merge/finish")
void worktreeMergeFinish(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    string target = routeParameter!"/api/worktrees/<name>/merge/finish"(request);
    JSONValue data = readBody(request);
    if ("source" !in data.object || data["source"].type != JSONType.string)
        throw new InvalidInputException("A source worktree is required");

    respond(output, worktreeManager.mergeFinish(target, data["source"].str));
}
