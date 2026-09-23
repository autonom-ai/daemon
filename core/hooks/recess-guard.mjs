// PreToolUse — recess is enforced, not requested.
//
// While the recess marker is open the team has stopped working, and this hook
// is the rule that says so: edits are blocked by the permission layer, while
// reads, searches, the agent's own profile (identity.md + memory.md in the
// clone), and the workspace's .devin/collaboration/ notebook stay open — a
// recess is exactly where memory and notes get written. Prompt text asking for
// "minimal edits" was advice; this is the boundary.
//
// Coverage is wider than the editor tools alone, because a shell command is a
// write channel too: `exec` calls get their command text scanned for
// redirections and write-shaped verbs (tee, sed -i, cp/mv, rm, mkdir, dd of=,
// inline interpreter writes), `write_to_process` is blocked outright (the
// hook cannot inspect what a live shell would do with the bytes), and
// non-coord MCP tools whose names are write verbs are refused. The exemption
// set is identical everywhere: the collaboration notebook, the caller's own
// profile dir, and scratch space under the OS temp dir.
//
// Blocking returns {"decision":"block","reason":...} — the reason is shown to
// the agent, so it sees what was refused and what is still in bounds.

import { existsSync, realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { AGENTS_HOME, PROJECT_DIR, claimFor, emit, hookInput, recess } from "./coord.mjs";

const input = await hookInput();
if (!recess().active)
    process.exit(0);
const tool = input.tool_name ?? "";

const agent = claimFor(input.session_id);

function block(reason)
{
    emit({ decision: "block", reason });
    process.exit(0);
}

const collaboration = path.join(PROJECT_DIR, ".devin", "collaboration");
const agentDir = agent ? path.join(AGENTS_HOME, agent) : null;

// Symlink-aware containment: resolve the deepest EXISTING ancestor of the
// target (and of the root) so a symlinked directory inside an exempt area
// cannot smuggle a write outside it, and a symlinked parent cannot make an
// outside path look inside. Files that do not exist yet resolve their real
// parent and keep their tail.
function realpathDeep(file)
{
    const tail = [];
    let cur = file;
    while (!existsSync(cur))
    {
        tail.unshift(path.basename(cur));
        const parent = path.dirname(cur);
        if (parent === cur)
            break;
        cur = parent;
    }
    try
    {
        cur = realpathSync(cur);
    }
    catch { }
    return path.join(cur, ...tail);
}

function within(root, target)
{
    if (!root)
        return false;
    const rel = path.relative(realpathDeep(root), realpathDeep(target));
    return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function exempt(target)
{
    return within(collaboration, target) || within(agentDir, target)
        || within(os.tmpdir(), target);
}

const OPEN_HINT = "Reads, searches, your own profile and .devin/collaboration/ notes stay open; close the recess with tools/coord-recess end.";

// A file-tool call whose payload we cannot read is refused rather than waved
// through: the matcher already proved this invocation is write-shaped, and an
// unreadable write is not a read.
// A call whose payload carries no tool name is refused rather than waved
// through: the hook only runs on write-shaped matchers, and an unreadable
// write is not a read.
if (!tool)
    block(`Recess is open — an unreadable tool call cannot be shown to be read-only, so it is refused. ${OPEN_HINT}`);
const FILE_TOOLS = /^(edit|write|apply_patch|notebook_edit)$/;
if (!FILE_TOOLS.test(tool) && tool !== "exec" && tool !== "write_to_process"
    && !/^mcp__/.test(tool))
    process.exit(0);

// A live shell stdin is an uninspectable write channel: the bytes could be
// `rm -rf` as easily as Enter, and the hook cannot tell which.
if (tool === "write_to_process")
    block(`Recess is open — writing to a running process is refused while the workspace is frozen. ${OPEN_HINT}`);

// The coord bus stays open during recess (recess IS talk), so agent-coord MCP
// calls pass. Other MCP tools are refused only when the name itself is a file
// verb — a workspace that routes a filesystem server through MCP gets the same
// freeze.
if (/^mcp__/.test(tool))
{
    if (/^mcp__agent-coord-/.test(tool))
        process.exit(0);
    if (/(^|_)(write|edit|create|delete|rename|mkdir|upload|apply_patch)(_|$)/i.test(tool))
        block(`Recess is open — ${tool} looks write-shaped and is refused. ${OPEN_HINT}`);
    process.exit(0);
}

if (tool === "apply_patch")
    block(`Recess is open — bulk patches are blocked. ${OPEN_HINT}`);

// ---- exec: extract write targets from shell command text ----------------
//
// Quote-aware light tokenizer: good enough for the common write shapes, and
// deliberately fails closed on the shapes it cannot see inside (interpreter
// one-liners, subshell bodies). A recess false-positive is cheap — the reason
// says what was refused — while a missed write is the bug this exists to kill.

function shellTokens(command)
{
    const tokens = [];
    let cur = "";
    let quote = null;
    let escaped = false;
    for (const ch of command)
    {
        if (escaped) { cur += ch; escaped = false; continue; }
        if (ch === "\\" && quote !== "'") { escaped = true; continue; }
        if (quote) { if (ch === quote) quote = null; else cur += ch; continue; }
        if (ch === "'" || ch === '"') { quote = ch; continue; }
        if (/[;&|]/.test(ch)) { if (cur) tokens.push(cur); tokens.push(ch); cur = ""; continue; }
        if (/\s/.test(ch)) { if (cur) { tokens.push(cur); cur = ""; } continue; }
        cur += ch;
    }
    if (cur) tokens.push(cur);
    return tokens;
}

const PATH_WRITE_VERBS = new Set(["rm", "rmdir", "mkdir", "touch", "truncate", "shred", "chmod", "chown", "chattr", "ln"]);
const DEST_WRITE_VERBS = new Set(["cp", "mv", "install", "rsync", "scp"]);
const GIT_TREE_WRITES = new Set(["checkout", "restore", "clean", "reset", "apply", "merge", "rebase", "stash", "rm", "mv", "cherry-pick", "revert", "add", "commit", "push", "pull", "fetch", "init", "clone", "tag", "config", "worktree"]);
const INLINE_WRITE = /open\s*\([^)]*['"][wax+]|writeFile|fs\.write|\.write_text|createWriteStream|\.writeBytes|FileUtils\.write/i;
// The tokenizer strips quotes, so `open("f","w")` arrives as `open(f,w)` —
// the bare variant matches the mode-arg shape without needing a quote.
const INLINE_WRITE_BARE = /open\s*\([^)]*,\s*[wax+]\s*[,)]|writeFile|fs\.write|\.write_text|createWriteStream|\.writeBytes|FileUtils\.write/i;

function isEnvPrefix(token)
{
    return /^[A-Za-z_][A-Za-z0-9_]*=/.test(token) || ["sudo", "env", "command", "nice", "time", "ulimit", "cd", "xargs"].includes(token);
}

// Returns { targets: [..], blindWrite: bool } — blindWrite marks commands that
// clearly write but whose target cannot be extracted (inline code, tree-wide
// git subcommands). Inline code that scans read-only passes.
function execWriteTargets(command)
{
    const tokens = shellTokens(command);
    const targets = [];
    let blindWrite = false;
    let verb = null;
    let sedInPlace = false;
    let dlNamed = false;
    let expectRedirectTarget = false;
    let expectInlineCode = false;
    let sawInterpreter = false;
    const positionals = [];
    for (const token of tokens)
    {
        if (/^[;&|]+$/.test(token))
        {
            // Command boundary: judge the finished verb, reset.
            blindWrite ||= judgeVerb(verb, positionals, targets);
            verb = null;
            sedInPlace = false;
            dlNamed = false;
            expectInlineCode = false;
            positionals.length = 0;
            expectRedirectTarget = false;
            continue;
        }
        if (expectRedirectTarget)
        {
            targets.push(token);
            expectRedirectTarget = false;
            continue;
        }
        const redirect = /^(\d*|&)?(>>?)(.*)$/.exec(token);
        if (redirect && !/>&\d/.test(token))
        {
            if (redirect[3])
                targets.push(redirect[3]);
            else
                expectRedirectTarget = true;
            continue;
        }
        if (!verb)
        {
            if (isEnvPrefix(token))
                continue;
            verb = token;
            if (/^(python[\d.]*|node|perl|ruby|php|bash|sh)$/.test(path.basename(verb)))
                sawInterpreter = true;
            continue;
        }
        if (expectInlineCode)
        {
            expectInlineCode = false;
            // bash/sh -c carries shell — recurse the same scan on the body.
            // Other interpreters get a write-call scan on the code text; a
            // body that writes marks blindWrite since its target is inside
            // code this parser cannot reliably resolve.
            if (/^(ba)?sh$/.test(path.basename(verb)))
            {
                const inner = execWriteTargets(token);
                targets.push(...inner.targets);
                blindWrite ||= inner.blindWrite;
            }
            else if (INLINE_WRITE.test(token) || INLINE_WRITE_BARE.test(token))
                blindWrite = true;
            continue;
        }
        if (verb === "sed" && /^-i|^--in-place/.test(token)) { sedInPlace = true; continue; }
        if (verb === "dd" && token.startsWith("of=")) { targets.push(token.slice(3)); continue; }
        // Downloads are writes: curl -o/--output and wget -O name the file;
        // curl -O and bare wget write the cwd, so the URL operand marks it.
        if (verb === "curl" && /^-o$|^--output$/.test(token)) { expectRedirectTarget = true; continue; }
        if (verb === "wget" && /^-O$/.test(token)) { expectRedirectTarget = true; dlNamed = true; continue; }
        if (verb === "curl" && /^-O$/.test(token)) { targets.push("."); continue; }
        if (verb === "wget" && !token.startsWith("-") && !dlNamed) { targets.push("."); continue; }
        if (verb === "git" && positionals.length === 0 && GIT_TREE_WRITES.has(token))
        {
            blindWrite = true; // tree-writing subcommand; targets are repo-wide
            continue;
        }
        if (/^(python[\d.]*|node|perl|ruby|php|bash|sh)$/.test(path.basename(verb)) && /^-[ec]$/.test(token))
        {
            expectInlineCode = true; // the next token is the code body
            continue;
        }
        if (token.startsWith("-"))
            continue;
        positionals.push(token);
    }
    blindWrite ||= judgeVerb(verb, positionals, targets, sedInPlace);
    // Interpreter present anywhere: scan the RAW command text for write-call
    // shapes. Token quotes are stripped, so the positionals check inside
    // judgeVerb cannot see `'w'` modes — the raw text still has them. This
    // covers -e/-c bodies, heredoc-fed code, and stray code strings alike.
    if (sawInterpreter && INLINE_WRITE.test(command))
        blindWrite = true;
    return { targets, blindWrite };

    function judgeVerb(v, args, out, inPlace = sedInPlace)
    {
        if (!v)
            return false;
        const base = path.basename(v);
        if (PATH_WRITE_VERBS.has(base))
            out.push(...args);
        else if (DEST_WRITE_VERBS.has(base) && args.length)
            out.push(args[args.length - 1]);
        else if (base === "tee")
            out.push(...args.filter((a) => !a.startsWith("-")));
        else if (base === "sed" && inPlace && args.length)
            out.push(args[args.length - 1]);
        // Interpreter verbs: heredoc-fed and stray code bodies land in
        // positionals — a write-call shape in any of them is a write whose
        // target lives inside code.
        if (/^(python[\d.]*|node|perl|ruby|php|bash|sh)$/.test(base))
            return args.some((a) => INLINE_WRITE.test(a) || INLINE_WRITE_BARE.test(a));
        return false;
    }
}

if (tool === "exec")
{
    const command = input.tool_input?.command;
    if (typeof command !== "string" || !command.trim())
        process.exit(0);
    const cwd = typeof input.tool_input?.workdir === "string" ? input.tool_input.workdir : PROJECT_DIR;
    const { targets, blindWrite } = execWriteTargets(command);
    for (const target of targets)
    {
        const resolved = path.resolve(cwd, target);
        if (!exempt(resolved))
            block(`Recess is open — \`${command.slice(0, 80)}\` writes ${resolved}, which is outside the recess-open areas. ${OPEN_HINT}`);
    }
    if (blindWrite)
        block(`Recess is open — \`${command.slice(0, 80)}\` contains a write this hook cannot see inside (inline code or a tree-writing git subcommand), so it is refused. ${OPEN_HINT}`);
    process.exit(0);
}

// ---- file tools ----------------------------------------------------------

const target = input.tool_input?.file_path ?? input.tool_input?.notebook_path;
if (!target)
    block(`Recess is open — edits are blocked. ${OPEN_HINT}`);

const resolved = path.resolve(PROJECT_DIR, target);

// The stand-down marker is the human's release valve, not a seat's move.
if (path.basename(resolved) === "stand-down" && within(collaboration, resolved))
    block("Recess is open — stand-down is the user's call, not a seat's.");
if (exempt(resolved))
    process.exit(0);
block(agent
    ? `Recess is open — edits to ${resolved} are blocked. ${OPEN_HINT}`
    : "Recess is open — edits are blocked until you join: your profile has to be known before it can stay writable.");
