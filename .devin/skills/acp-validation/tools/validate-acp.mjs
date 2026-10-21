#!/usr/bin/env node
// Validates ACP JSON-RPC notifications and reducer behavior against the installed Devin Desktop bundle.

import fs from "node:fs";
import Module from "node:module";
import path from "node:path";

const ACP_BUNDLE = "/usr/share/devin-desktop/resources/app/node_modules/@exa/windsurf-acp/index.cjs";

function loadInstalledAcp()
{
    if (!fs.existsSync(ACP_BUNDLE))
        throw new Error(`Installed ACP bundle not found at ${ACP_BUNDLE}`);

    const mod = new Module(ACP_BUNDLE);
    mod.filename = ACP_BUNDLE;
    mod.paths = Module._nodeModulePaths(path.dirname(ACP_BUNDLE));
    const source = fs.readFileSync(ACP_BUNDLE, "utf8") + "\nmodule.exports.__autonomAudit = {" +
        "createAcpIncomingMessageValidator," +
        "reduceSessionNotification: typeof reduceSessionNotification !== 'undefined' ? reduceSessionNotification : null" +
        "};\n";
    mod._compile(source, ACP_BUNDLE);
    return mod.exports.__autonomAudit;
}

function defaultSamples()
{
    return [
        {
            name: "v1 user_message_chunk with clientMessageId + messageSubIndex",
            sessionId: "autonom-room-general",
            update: {
                sessionUpdate: "user_message_chunk",
                content: { type: "text", text: "Hello room" },
                _meta: {
                    "cognition.ai/clientMessageId": "msg-1",
                    "cognition.ai/messageSubIndex": 0,
                },
            },
            expectValid: true,
        },
        {
            name: "v1 agent_message_chunk with sender metadata",
            sessionId: "autonom-room-general",
            update: {
                sessionUpdate: "agent_message_chunk",
                content: { type: "text", text: "marlow: Ready" },
                _meta: {
                    "autonom/sender": "marlow",
                    "cognition.ai/streamingMessageId": "msg-2",
                },
            },
            expectValid: true,
        },
        {
            name: "v1 agent_thought_chunk",
            sessionId: "autonom-profile-marlow",
            update: {
                sessionUpdate: "agent_thought_chunk",
                content: { type: "text", text: "Checking repository state." },
            },
            expectValid: true,
        },
        {
            name: "v1 tool_call and tool_call_update",
            sessionId: "autonom-profile-marlow",
            update: {
                sessionUpdate: "tool_call",
                toolCallId: "call-1",
                title: "exec",
                kind: "execute",
                status: "in_progress",
                rawInput: { command: "ls" },
            },
            expectValid: true,
        },
        {
            name: "v1 session_info_update title",
            sessionId: "autonom-profile-marlow",
            update: {
                sessionUpdate: "session_info_update",
                title: "marlow",
            },
            expectValid: true,
        },
        {
            name: "invalid v2 user_message on v1 connection (must reject)",
            sessionId: "autonom-room-general",
            update: {
                sessionUpdate: "user_message",
                content: [{ type: "text", text: "bad" }],
            },
            expectValid: false,
        },
    ];
}

function main()
{
    const { createAcpIncomingMessageValidator } = loadInstalledAcp();
    const validateV1 = createAcpIncomingMessageValidator(1);
    const args = process.argv.slice(2);

    if (args[0] === "--file" && args[1])
    {
        const lines = fs.readFileSync(args[1], "utf8").split(/\r?\n/).filter(Boolean);
        let checked = 0;
        for (const line of lines)
        {
            const frame = JSON.parse(line);
            if (frame.method === "session/update")
            {
                validateV1("session/update", frame.params);
                checked += 1;
            }
        }
        console.log(`Validated ${checked} session/update frame(s) against installed ACP v1 schema.`);
        return;
    }

    for (const sample of defaultSamples())
    {
        let accepted = false;
        let errorMessage = "";
        try
        {
            validateV1("session/update", { sessionId: sample.sessionId, update: sample.update });
            accepted = true;
        }
        catch (error)
        {
            accepted = false;
            errorMessage = error instanceof Error ? error.message : String(error);
        }

        if (accepted !== sample.expectValid)
        {
            console.error(`FAIL: ${sample.name}: expected ${sample.expectValid}, got ${accepted} (${errorMessage})`);
            process.exit(1);
        }
        console.log(`PASS: ${sample.name}`);
    }
}

main();
