#!/usr/bin/env node
// Verify the Autonom extension-host bridge from inside the live Devin Desktop page:
// reads the private descriptor over vscode-file, authenticates with the capability, and
// exercises GET /state and optionally POST /action. No page reload and no DOM fabrication.
//
//   node scripts/bridge-check.mjs
//   node scripts/bridge-check.mjs --action '{"type":"select","destination":{"kind":"room","id":"general"}}'

import { CdpSession } from "./cdp.mjs";

const args = process.argv.slice(2);
const actionIndex = args.indexOf("--action");
const action = actionIndex >= 0 ? args[actionIndex + 1] : null;

const match = { urlIncludes: process.env.CC_TARGET || "workbench.html" };
const session = await CdpSession.open(match).catch((error) => {
    console.error(error.message);
    process.exit(1);
});

try {
    const result = await session.evaluateFunction(async (actionJson) => {
        const output = {};
        try {
            const descriptorUrl = new URL("vs/sessions/autonom.bridge.json", globalThis._VSCODE_FILE_ROOT).href;
            const descriptorResponse = await fetch(descriptorUrl, { cache: "no-store" });
            if (!descriptorResponse.ok) {
                return { stage: "descriptor", ok: false, status: descriptorResponse.status };
            }
            const descriptor = await descriptorResponse.json();
            output.descriptor = { version: descriptor.version, port: descriptor.port, capabilityLength: descriptor.capability?.length };
            const headers = { "x-autonom-bridge": descriptor.capability };
            const stateResponse = await fetch(`http://127.0.0.1:${descriptor.port}/state`, { headers, cache: "no-store" });
            const state = await stateResponse.json();
            output.state = {
                ok: stateResponse.ok,
                status: stateResponse.status,
                connected: state.connected,
                error: state.error ?? null,
                rooms: Array.isArray(state.rooms) ? state.rooms.length : null,
                profiles: Array.isArray(state.profiles) ? state.profiles.length : null,
                sessions: Array.isArray(state.sessions) ? state.sessions.length : null,
                runs: Array.isArray(state.daemon?.runs) ? state.daemon.runs.length : null,
                settings: state.settings ?? null,
            };
            output.roomNames = Array.isArray(state.rooms) ? state.rooms.map((room) => room.name).slice(0, 20) : [];
            output.profileNames = Array.isArray(state.profiles) ? state.profiles.map((profile) => profile.name).slice(0, 20) : [];
            if (actionJson) {
                const actionResponse = await fetch(`http://127.0.0.1:${descriptor.port}/action`, {
                    method: "POST",
                    headers: { ...headers, "content-type": "application/json" },
                    body: actionJson,
                });
                const payload = await actionResponse.json();
                output.action = { ok: actionResponse.ok, status: actionResponse.status, result: payload.result ?? null, error: payload.error ?? null };
            }
        } catch (error) {
            output.error = String(error);
        }
        return output;
    }, action);
    console.log(JSON.stringify(result, null, 2));
} catch (error) {
    console.error(error.message);
    process.exit(1);
} finally {
    session.close();
}
