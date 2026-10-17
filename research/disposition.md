# File and Folder Dispositions

## Scope and interpretation

This is the actionable companion to [plan.md](plan.md), using the user's
clarified requirements and adopted [style revision](style-rules-revision.md).
It is not a record of changes already made. No production file or user data
has been removed.

The implementation inventory is the tracked tree at `08a8af4`. The existing
nine research documents were added at `111121c`; they are listed separately.
[daemon-map.md](daemon-map.md) and [repo-map.md](repo-map.md) retain detailed
current responsibilities, dependencies, side effects, and source evidence.
This document supplies recommendations rather than duplicating those traces.

**Keep** preserves a justified boundary, not every existing line.
**Simplify** changes its implementation without dropping its core capability.
**Fold** removes a forwarding/fragmentation surface by integrating its work
with the real owner. **Replace** changes the model substantially.
**Remove** means remove source after its real consumers and required behavior
have been migrated; it never means silently delete persisted data or a live
deployment reference. **Repair** corrects stale guidance or build contracts.

Priorities follow the plan: first adopt reliable guidance/direct installation,
then integrate the database/Session/ACP ownership slice, then remove obsolete
execution/permission/relay machinery and complete the core views. Do not
execute this table as an independent file-deletion checklist.

## Folder breakdown

| Folder | Responsibility and recommendation |
| --- | --- |
| Repository root | Build/package/license/guidance and installer entrypoints. Replace `install.sh` with direct `install.py`; keep exact dependency locks and concise guidance. |
| `.github/` | Automation configuration; keep. |
| `.github/workflows/` | Run actual build/test targets, not the nonexistent eval configuration. |
| `assets/` | Configurable Command Center presentation; keep and integrate the core live views. |
| `assets/actions/` | Explicit configured JavaScript actions; keep without introducing plugin infrastructure. |
| `assets/icons/` | Active/inactive mode-switch SVGs; keep the resources actually used. |
| `assets/pages/` | Core Events/Schedules/Policy/Settings pages; complete real data/actions, share repeated presentation where useful, no special permission UI. |
| `docs/` | Real Desktop integration and observation-only acceptance contracts; keep and repair stale commands. |
| `source/` | Language-specific production and test roots; keep, no universal application framework. |
| `source/daemon/` | Loopback HTTP runtime and meaningful domain owners; keep one mutable-state worker and explicit resource lifetimes. |
| `source/daemon/agent/` | Durable profile identity and session assignment; keep. |
| `source/daemon/coord/` | Rooms, membership, message streams, and cursors; keep and audit locally. |
| `source/daemon/events/` | Pending events, schedules, wake recovery, and clock; keep, integrate directly with Bridge/Session. |
| `source/daemon/interop/` | Concrete bridge-owned CLI/process behavior, canonical Session, database access, scoped capabilities, and protocol integration; fundamentally simplify. |
| `source/daemon/interop/acp/` | Shared frame/connection/protocol handling; replace the tap/injection stack with direct modifiable frames. |
| `source/daemon/interop/devin/` | Current single-backend forwarding hierarchy plus real DB/hook integration. Fold wrappers; keep real adapters with their owner; no speculative backend framework or legacy shim. |
| `source/daemon/policy/` | Workspace rules and Intuit screening; retain enforcement and review direct implementation. |
| `source/daemon/relay/` | Current connector executable, observer, and injection-control hierarchy. Remove the stack after shared frame handling preserves native Desktop behavior; retain the necessary stdio entrypoint, not another relay framework. |
| `source/launcher/` | Desktop process, private CDP, native runtime, configuration, finite bridge actions; retain imperative ownership. |
| `source/launcher/tests/` | Shared unit fixtures and test organization; keep explicitly distinct from live acceptance. |
| `source/launcher/tests/unit/` | Actual transport/config/runtime/install contract tests; keep and update behavior assertions. |
| `source/mcp/` | Genuine external MCP stdio adapter and Python tests; retain, without duplicating Session ownership. |
| `source/tests/` | D domain/protocol/HTTP tests and fake CLI fixture; preserve useful coverage while replacing implementation-specific assertions. |
| `templates/` | Starting configuration and hook/policy installation contracts; keep meaningful artifacts, remove the empty static MCP placeholder. |
| `research/` | Source snapshots, evidence, adopted style, plan, and dispositions; retain the distinction between historical observations and future architecture. |

Ignored/local paths such as `bin/`, `dist/`, `.dub/`, launcher `node_modules/`,
`__pycache__/`, `.devin/`, and empty scratch directories are not tracked
production-source modules. Do not delete private configuration, live data,
or generated output merely because the inventory excludes it.

## Root, automation, build, and documentation

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `.github/workflows/ci.yml` | D build/unit/eval workflow | Repair | Remove the undeclared eval step; cover actual D, Node, and Python checks. Installed-Desktop-dependent tests need explicit fixture/environment handling, not a false live gate. |
| `.gitignore` | Private/generated path exclusions and documentation exceptions | Keep | Preserve private data exclusions; narrowly expose requested audit documents. |
| `AGENTS.md` | Verification, runtime, route, and Desktop instruction dump | Replace | Short verified commands, source owners, essential invariants, adopted style, and authoritative links. Remove stale eval/script/schema claims rather than append another contract. |
| `LICENSE.txt` | AGPL license | Keep | No architectural change. |
| `dub.json` | Daemon/unit/ACP executable configurations and dependencies | Simplify | Keep real entrypoints, replace relay source layout during ACP cutover, remove stale eval exclusions, update unit pre-build targets together. |
| `dub.selections.json` | Resolved D dependency versions | Keep | Preserve reproducibility; remove a dependency only after its last real consumer disappears. |
| `install.sh` | Bash build gate around Python transactional installer | Replace | Root `install.py`; port existing Python directly, keep flags/security/rollback, update tests/docs/recovery text together, no shell compatibility wrapper. |
| `docs/COMMAND_CENTER.md` | Native Desktop adapter contract | Repair | Preserve integrity/native restoration rules; synchronize entrypoints, actual actions, permission ownership, and available validation commands. |
| `docs/COMMAND_CENTER_VALIDATION.md` | Live acceptance methodology | Keep/repair | Keep observation-only evidence and exact-target isolation; repair absent integration-script references and installer command names. |

## Assets

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `assets/ATTRIBUTION.md` | Icon attribution/license notice | Keep | Retain while the attributed marks are shipped. |
| `assets/actions/reload.js` | Configurable reload action example | Keep | Direct `context.refresh()` action; an example is not a reason to add dispatch infrastructure. |
| `assets/icons/autonom-fill.svg` | Active Autonom mark | Keep | Used by native mode switch. |
| `assets/icons/autonom.svg` | Inactive Autonom mark | Keep | Used by native mode switch. |
| `assets/icons/cloud-fill.svg` | Active Cloud mark | Keep | Used by native mode switch. |
| `assets/icons/cloud.svg` | Inactive Cloud mark | Keep | Used by native mode switch. |
| `assets/icons/pencil-fill.svg` | Active Editor mark | Keep | Used by native mode switch. |
| `assets/icons/pencil.svg` | Inactive Editor mark | Keep | Used by native mode switch. |
| `assets/pages/events.html` | Static inbox/bus presentation and state request | Replace | Consume actual event responses, render genuine states, and perform real authorized actions; no fake acknowledgement/health. Events remain core. |
| `assets/pages/policy.html` | Hardcoded rule presentation, filter, edit action | Replace | Real workspace rule/enforcement state and edit/verification behavior; remove fake rules/verify alerts without weakening policy. |
| `assets/pages/schedules.html` | Static clock/schedule presentation and refresh request | Replace | Live schedules and real controls backed by the existing domain; do not omit a core feature to simplify the UI. |
| `assets/pages/settings.html` | Actual launcher/daemon settings form | Simplify | Adopt native-language style and shared presentation/request code; await both writes, report partial failure, remove fake preview-save success. |
| `assets/ui.css` | Scoped injected switch/page styles | Keep | Preserve native tokens and isolated styling; share page styles only where actually reused. |
| `assets/ui.yml` | Ordered HTML/native/JS navigation configuration | Keep/simplify | Retain core pages and explicit native imports; avoid speculative placeholder functionality and hardcoded imports. |

## Daemon composition and shared support

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `source/daemon/app.d` | Serverino executable/endpoint composition | Keep | Update actual endpoint list during owner cutovers; no extra application layer. |
| `source/daemon/package.d` | Top-level public exports | Keep | Export actual useful domain APIs, not obsolete subtypes. |
| `source/daemon/server.d` | Worker/HTTP lifecycle, authorization, refresh, errors | Simplify | Preserve one state owner, bounded/nonblocking process work, explicit teardown, and genuine auth distinctions. |
| `source/daemon/runtime.d` | Shared instance construction and close ordering | Simplify | Keep composition visible; integrate with the worker owner where useful, not another service registry or a mandatory merge solely to reduce files. |
| `source/daemon/config.d` | YAML/path/duration/router configuration | Simplify | Keep the direct validated configuration model and private keys; no arbitrary settings factory or speculative router framework. |
| `source/daemon/storage.d` | Bounded owned reads and atomic private writes | Keep | Real filesystem invariant; preserve symlink refusal, durable writes, and data through migrations. |
| `source/daemon/exception.d` | Input/conflict/backend errors | Keep | Small meaningful failure vocabulary, not a generic error hierarchy. |
| `source/daemon/http.d` | HTTP shape/response/caller helpers | Simplify | Keep transport validation/auth at the edge and eliminate obsolete Execution/session-ID coupling. |
| `source/daemon/client.d` | Client state/transcript/message/model aggregation | Simplify | Serialize the shared database-backed Session catalog and real domain state; keep file logs and native/HTTP permissions, no copied alternate catalog. |
| `source/daemon/hooks.d` | Authenticated CLI policy/event/lifecycle endpoints | Simplify | Preserve PreToolUse enforcement and event context; integrate session identity/capabilities, remove redundant human queue only after ACP coverage is demonstrated. |

## Profiles, coordination, events, and policy

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `source/daemon/agent/package.d` | Profile/store public exports | Keep | Useful D package surface. |
| `source/daemon/agent/profile.d` | Profile binding/model and detail endpoint | Keep/simplify | Preserve actual identity; canonical Session association, without a forwarding session hierarchy or hidden alternate lookup. |
| `source/daemon/agent/store.d` | Durable profile snapshot/assignment and routes | Simplify | Preserve assignments and failure atomicity; migrate legacy data explicitly and remove recurring compatibility loaders after cutover. |
| `source/daemon/coord/package.d` | Bus/room/stream exports | Keep | Real cohesive package. |
| `source/daemon/coord/access.d` | Coordination HTTP routes and validation | Keep/simplify | Direct handlers remain; use canonical Session authorization and preserve visibility/read/event invariants. |
| `source/daemon/coord/bus.d` | Room/inbox streams and cursors | Keep | Real coordination owner; audit local duplication/style without folding it into Session or pending events. |
| `source/daemon/coord/room.d` | Membership/admin/visibility persistence | Keep | Preserve ownership and authorization rules. |
| `source/daemon/coord/stream.d` | JSONL history, Entry, bounded in-memory stream | Keep | File history and unread state are distinct; preserve append/read behavior and buffer ownership. |
| `source/daemon/events/package.d` | Event/schedule/scheduler exports | Keep | Export concrete domain owners. |
| `source/daemon/events/event.d` | Pending events, persistence, read/clear route | Keep | Core unread-event owner, not duplicate message history. |
| `source/daemon/events/schedule.d` | Schedule parsing/matching/persistence/routes | Keep | Core schedule domain; retain clock/event validation and durable data. |
| `source/daemon/events/scheduler.d` | Clock/wake delivery and restart reconciliation | Simplify | Canonical Session/Bridge results, explicit compact-then-resume, existing durable wake intent, no generic Execution dependency graph or uncertain prompt replay. |
| `source/daemon/policy/package.d` | Policy exports | Keep | Cohesive API. |
| `source/daemon/policy/access.d` | Rule evaluation, Intuit screening, HTTP check | Keep/simplify | Actual external library boundary; preserve fail-closed behavior, timeout, and context cleanup. No new policy/approval engine. |
| `source/daemon/policy/rule.d` | Workspace policy parser/matcher | Keep | Preserve first-match semantics and bounded validated policy loading. Model/prompt/threshold changes are not part of this architectural cleanup. |

## Interop and ACP

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `source/daemon/interop/package.d` | Interop facade | Keep/simplify | Concise Bridge/Session API; remove legacy implementation exports after callers migrate. |
| `source/daemon/interop/bridge.d` | Abstract bridge, execution/session/observation registries | Replace | Concrete CLI/process owner exposing all database sessions and ACP filters; one canonical lookup and minimal active operations, not parallel catalogs. |
| `source/daemon/interop/session.d` | Abstract Session, execution binding, metadata access and routes | Replace | Canonical database-backed Session with real live connection/operation state and HTTP/native permission association. Keep useful endpoints directly, not an abstract forwarding ladder. |
| `source/daemon/interop/metadata.d` | Metadata value/serialization | Fold | Co-locate the Session metadata view where it clarifies ownership; keep a separate value only if genuinely shared, not as an extra public facade. |
| `source/daemon/interop/execution.d` | Generic task/process/persistence/steering/HTTP model | Remove framework | Migrate actual child cancellation, async outcomes, scheduler/auth/client callers into Bridge; retain file logs/all durable data. Do not replace it with the same machinery called `operation.d`, or break useful HTTP behavior just to remove a class. |
| `source/daemon/interop/process.d` | Process groups, parent-death signal, env/reap helpers | Keep | Real OS resource boundary, reused by bridge/ACP paths. |
| `source/daemon/interop/access.d` | Operator/run/MCP grants plus managed membership | Simplify | Scoped capability-to-Session/connection binding and revocation; never use authorization as discovery or ACP provenance. Remove dead flags/registries only after their actual consumers migrate. |
| `source/daemon/interop/permission.d` | Detached global request store and HTTP polling/decision API | Remove detached model | Preserve useful HTTP behavior backed by Session/connection pending requests and native Desktop responses. No custom UI, independent history, copied metadata, or redundant approval loop. |
| `source/daemon/interop/mcp.d` | Coord MCP injection, relay admission, token resolution | Simplify | Inject/resolve actual session capabilities on authoritative frame handling; preserve unrelated MCP servers and auth. Remove extra observation/admission plumbing when the shared connection owns it. |
| `source/daemon/interop/acp/package.d` | ACP exports | Keep/simplify | Export actual frame/connection API rather than observer/injection facades. |
| `source/daemon/interop/acp/client.d` | Spawned ACP client, parsing, correlation, callbacks | Replace | Shared connection implementation with direct frame handling and nonblocking pending requests; preserve native capabilities and all required directions. |
| `source/daemon/interop/acp/frames.d` | Header scanner, tap, queue, direction/IO support | Replace | Owned complete modifiable frame value/codec; no lossy tap or second header representation. Rename only when it reflects the new responsibility. |
| `source/daemon/interop/acp/relay.d` | Byte forwarding, optional rewriting/injection/consumption | Remove stack | Shared frame read/handle/modify/write path, with actual routing/cancellation preserved; do not keep arbitrary-byte proxy behavior as an accidental product requirement. |
| `source/daemon/interop/devin/package.d` | Backend subtype exports | Fold | Public surface belongs to interop; no empty forwarding package needed after subtype removal. |
| `source/daemon/interop/devin/bridge.d` | Concrete CLI operations, locks, metadata, observed-session routes | Fold/rethink | Actual CLI operations and lock semantics belong to concrete Bridge; database listing replaces unused subprocess listing; no duplicate observed-session catalog. |
| `source/daemon/interop/devin/session.d` | Session subtype forwarding to Devin | Remove subtype | Preserve behavior in the canonical Session/Bridge, including foreign lock safety and native connection ownership. |
| `source/daemon/interop/devin/acp.d` | ACP tasks/options/permissions plus socket control runner | Fold/rethink | One protocol/connection path for create/load/prompt/options/cancel; native permission responses instead of unconditional rejection; no duplicated task/control runners. |
| `source/daemon/interop/devin/db.d` | Read-only SQLite metadata/history reader | Keep/extend | Database enumeration and batch metadata, persisted ACP filter mapping, and history; no DB writes or process-running inference. A `database.d` owner name is reasonable during hierarchy collapse, not a standalone cosmetic rename. |
| `source/daemon/interop/devin/hook.py` | External CLI hook/HTTP process | Keep/simplify | Genuine external boundary; preserve policy/auth/fail-closed handling, retire duplicated approval polling only after coverage. Update path in installer/templates/tests together if moved; no compatibility copy. |
| `source/daemon/interop/devin/stub.py` | Hardcoded local stale-registry redirect | Remove | Explicitly update the external deployment pointer, then remove source. Do not silently edit the user's registry or retain the shim indefinitely. |
| `source/daemon/relay/package.d` | `autonom-acp` executable startup | Replace entrypoint | Keep the necessary native stdio executable with direct shared frame/connection use; update DUB/install/registry references, no separate relay subsystem. |
| `source/daemon/relay/agent.d` | Observed sessions, admission, heartbeat, frame rewrite/control coordination | Remove stack | Required admission/activity changes move into authoritative frame handlers and canonical Session association. Preserve native UI behavior; no telemetry side channel as truth. |
| `source/daemon/relay/control.d` | Injection queue/socket/request-response facade | Remove facade | Retain only cross-process transport/correlation actually required for Desktop-owned sessions, using the same frames; no new broker, ID-prefix assumptions, or second request engine. |

## Launcher and MCP

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `source/launcher/assets.d.ts` | SVG/CSS import declarations | Keep | Actual build/type seam. |
| `source/launcher/bridge.ts` | Authenticated finite page actions/settings/state | Simplify | Real core page actions; no arbitrary generic proxy or special approval interface. Native permissions stay native; HTTP permission API belongs to daemon. |
| `source/launcher/build.mjs` | esbuild entrypoints/test bundling | Keep/update | Update actual installer/entrypoint references as needed; no build framework. |
| `source/launcher/build.ts` | Desktop/package pin and digest verification | Keep | Real shared integrity authority; preserve RPM ownership and build-generation checks. |
| `source/launcher/buildcli.ts` | Build-verifier executable adapter | Keep | Genuine Python-to-TypeScript verifier boundary used by `install.py`; do not duplicate the verifier merely to eliminate a small adapter. |
| `source/launcher/cdp.mjs` | Private control-socket CLI | Keep | Actual human inspection tool, not daemon ACP routing. |
| `source/launcher/cdp.ts` | CDP request/session/service capture | Keep/simplify | Real protocol owner; improve local naming/types without another abstraction over it. |
| `source/launcher/center.ts` | Browser-safe content model/pure overlay helpers | Keep | Genuine browser/Node authority boundary and useful pure behavior. |
| `source/launcher/client.ts` | Daemon health/capability/HTTP/startup client | Keep/simplify | Consume canonical Session catalog; existing MCP `--ensure` bootstrap is already shared, not a second independently implemented daemon starter. |
| `source/launcher/config.ts` | Safe files, UI loading, settings persistence | Simplify | Separate UI definition/loading from settings only where responsibility warrants; reuse actual file bounds/confinement, no generic schema/repository layer. |
| `source/launcher/control.ts` | Same-user private inspection socket | Keep | Real lifecycle/authority boundary distinct from ACP control. |
| `source/launcher/desktop.ts` | OS binary/spawn/environment/private CDP transport | Keep | Preserve pipe default, explicit loopback debug checks, and host environment isolation. |
| `source/launcher/launcher.ts` | Imperative startup/attachment/reload/shutdown | Keep/simplify | Keep lifecycle visible and serialized; no new orchestrator/manager. |
| `source/launcher/runtime.ts` | Native navigation/custom-page overlay and restoration | Simplify | Local native-shell/page lifecycle clarity and narrow private types; preserve lease, native handlers, atomic reload, and exact descriptor restore. No replacement app framework. |
| `source/launcher/package.json` | Node/tooling/scripts/dependencies | Keep/update | Actual scripts and Node 22+; no speculative dependencies. |
| `source/launcher/package-lock.json` | Exact npm dependency resolution | Keep | Preserve reproducibility. |
| `source/launcher/tsconfig.json` | Strict TS module/compiler contract | Keep | Adjust only for real code movement, not weaker validation. |
| `source/mcp/server.py` | MCP tools/stdio/HTTP adapter and shared daemon bootstrap | Simplify | Keep the real external protocol and finite tool dispatcher; resolve Session server-side from scoped capability, no caller-supplied identity or plugin system. |
| `source/mcp/tests.py` | Current MCP/hook capability contract tests | Keep/update | Current nine-test suite is fixed; preserve auth/failure coverage, adjust moved hooks and permission path, do not repeat the historical import failure as current. |

## Test files

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `source/launcher/tests/support.ts` | Synthetic native-service/content fixtures | Keep | Explicit unit seam, never live Desktop acceptance evidence. |
| `source/launcher/tests/unit/bridge.ts` | HTTP bridge auth/actions/settings contracts | Keep/update | Real page data/errors and partial-save handling; no manufactured approval UI. |
| `source/launcher/tests/unit/build.ts` | Pin/package/digest/refusal contracts | Keep | Preserve integrity and file-type checks. |
| `source/launcher/tests/unit/cdp.ts` | CDP framing/session/capture fixtures | Keep | Actual protocol behavior, not proof of a mounted native UI. |
| `source/launcher/tests/unit/center.ts` | YAML/UI schema, loading, path/revision contracts | Keep | Preserve configured imports/actions, bounds, confinement, and invalid snapshot rejection. |
| `source/launcher/tests/unit/config.ts` | Launcher/daemon configuration files | Keep | Preserve unrelated fields and path resolution; no secret output. |
| `source/launcher/tests/unit/content.ts` | Pure native overlay/CSP/content transforms | Keep | Useful behavior coverage; organize by actual owner, not automatic test-file consolidation. |
| `source/launcher/tests/unit/control.ts` | Temporary inspection socket protocol/ownership | Keep | Preserve refusal and same-user ownership tests. |
| `source/launcher/tests/unit/desktop.ts` | OS pipes/spawn/debug/environment/pin contracts | Keep | Preserve process isolation and explicit environment-sensitive build check; no live UI claims. |
| `source/launcher/tests/unit/install.ts` | Temporary install trees and rollback/refusal fault cases | Keep/port | Run direct `install.py`, preserving all transactional, argv, package-generation, and byte-exact invariants. |
| `source/launcher/tests/unit/runtime.ts` | Synthetic overlay/restoration/reload/lease contracts | Keep | Preserve useful unit assertions; live native rendering is a separate gate. |
| `source/tests/acp.d` | Byte relay, ACP client/MCP/control contracts | Replace implementation assertions | Test actual frames, mutations, routing/ID isolation, native permission pass-through, admission, limits, and EOF. Preserve useful behavior, not obsolete tap architecture. |
| `source/tests/bridge.d` | Canonical handles, subprocess listing/printing/removal | Keep/rewrite | Database-backed all-session catalog/filtering and CLI/process actions; remove the obsolete subprocess-list contract. |
| `source/tests/common.d` | Shared temp daemon/agent fixtures/helpers | Keep/update | Canonical Session/auth helpers; temporary resources and single loopback test worker. |
| `source/tests/config.d` | Config/path/router validation | Keep | Real configuration contract. |
| `source/tests/coord.d` | Streams/cursors/membership/visibility | Keep | Core feature regression coverage, not candidates for feature deletion. |
| `source/tests/daemon.d` | Integrated HTTP/hooks/coordination/capabilities | Keep/update | Database listing/filtering, HTTP/native permissions, canonical admission, and preservation of real core behavior. |
| `source/tests/database.d` | SQLite metadata/main-chain/history/file safety | Keep/extend | Add all-session enumeration, persisted ACP identity/filtering, metadata refresh, and restart catalog consistency. |
| `source/tests/events.d` | Pending events/schedules/wake behavior | Keep/update | Explicit bridge outcomes/compact sequence; preserve durable state and avoid duplicate wake prompts. |
| `source/tests/fakeagent.py` | Offline external CLI/ACP fixture | Keep | Necessary test seam, not legacy production code. Extend protocol negatives without pretending it proves installed Desktop behavior. |
| `source/tests/permission.d` | Detached PermissionStore/input-copy assertions | Replace | Session-associated HTTP/native decision routing, owned input, offered options, timeout/cancel/duplicate/cross-session cases; no standalone store requirement. |
| `source/tests/policy.d` | Rule/Intuit/failure/validation contracts | Keep | Preserve enforcement, unchanged model input, context clearing, and fail-closed behavior. |
| `source/tests/profile.d` | Profile snapshot/binding/legacy/storage contracts | Keep/update | Canonical Session and durable assignments; retire compatibility-format assertions only after explicit data migration. |
| `source/tests/session.d` | Session/process lifecycle and execution-format contracts | Keep/rewrite | Database-backed handles, native live state, errors/cancel/reload/log survival; obsolete record versions are not the new Session model. |

## Templates

| File | Current purpose | Verdict | Target and dependencies |
| --- | --- | --- | --- |
| `templates/config.yml` | Starting private daemon configuration | Keep/update | Preserve required data/CLI/router settings; update only actual changed options, not speculative defaults. |
| `templates/hooks.v1.json` | CLI hook event commands/timeouts | Simplify | Keep PreToolUse enforcement and real event context; update moved path/permission events only with tested ACP coverage and matching deployment changes. |
| `templates/mcp_config.json` | Empty static MCP server map | Remove placeholder | Dynamic session capability injection is authoritative; update installer/docs together, do not remove actual MCP functionality. |
| `templates/policy.yml` | Starting workspace policy | Keep | Actual enforcement template; no unrelated prompt/model/threshold rewrite. |

## Existing research and new review outputs

| File | Purpose and treatment |
| --- | --- |
| `research/README.md` | Entry index; distinguish evidence snapshots, adopted style, and current proposals. |
| `research/daemon-map.md` | Preserve the daemon inventory at its stated baseline; it is not a description of an implemented refactor. |
| `research/repo-map.md` | Preserve the rest-of-repository inventory and evidence boundaries. |
| `research/sessions-acp.md` | Preserve current-session/protocol traces; the user's clarifications resolve its product questions through the plan, not by rewriting historical evidence. |
| `research/permissions.md` | Preserve the old queue/hook/native integration evidence for migration and regression checks. |
| `research/reference-style.md` | Preserve source-derived comparison, including historical variations; adopted guidance is separate. |
| `research/style-rules-revision.md` | Adopted style baseline superseding the removed older rules; retain the language-semantic explanations. |
| `research/review.md` | Historical architecture research, explicitly not itself the new decision document. |
| `research/verification.md` | Recorded baseline commands/results and limitations; no relabeling as post-refactor or live acceptance. |
| `research/plan.md` | Current clarified requirements, architectural recommendations, phases, and acceptance gates. |
| `research/disposition.md` | This complete file/folder recommendation map; update if implementation changes the approved target. |
