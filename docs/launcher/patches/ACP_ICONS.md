# ACP icons

`patches/icons/catalog.ts` reads every registry agent with a nonempty string
`icon`, including disabled agents such as Antigravity. Provider IDs key the
resulting in-memory dictionary. It never rewrites registry metadata. Startup
connector registration remains separate and preserves existing icon fields;
new Autonom registrations need no persisted icon because the catalog supplies
the bundled Base64 fallback in memory.

## Asset boundary

`assets.ts` accepts image data URIs, HTTP(S), file URLs, and absolute/relative
file paths (relative to the registry directory). It emits canonical Base64 image
data URIs. Reads are bounded to 256 KiB per image; remote requests share a
three-second batch deadline, at most four concurrent loads, and three redirects.
The serialized provider dictionary (including fallback) and retained source-cache
records each have a four-MiB budget, eight MiB combined. Exhaustion stops further loads; already running reads
remain subject to the image and deadline bounds. Provider ordering follows the
registry, so response completion order does not trigger redundant renderer scans.
Unsupported MIME types and malformed sources fail independently. Logs identify
only the provider, without remote URLs or credential-bearing metadata.

Identical sources share one cached asset and concurrent reads share one refresh.
Local file metadata changes invalidate their cache. Remote successes refresh
after five minutes, failures retry after one minute, and a failed refresh retains
a previously successful asset. Removed sources are pruned. Remote conversion runs in the background, so attachment starts with the
in-memory Autonom fallback and does not wait for network icons. The registry is read
at most once per launcher refresh interval (five seconds); only the Base64
provider dictionary crosses CDP. The renderer performs no icon network fetches.

## Native hook

`providers.ts` finds an icon's provider through its own bounded React ancestry,
provider icon props, or an unambiguous session association. It does not infer
ownership from nearby labels. Traversal is capped at 128 steps and session
associations at 4096 entries.

`renderer.ts` patches icon masks and ACP codicon pseudo-elements. Each icon owns
its CSS/attribute snapshot through the shared lifecycle; the stylesheet is owned
by the patch. Mutation records dirty affected subtrees; unchanged heartbeats do
not rescan the document. Reused or disconnected elements restore their state.
Labels, inputs, and unrelated icons remain native.

## Validation

Real file/HTTP tests cover conversion, cache sharing/invalidation/removal,
response/redirect/deadline bounds, and unchanged registry bytes. In Desktop,
observe the actual Agents settings icon and provider session rows, then exercise
mode changes, remounts, hot replacement, detach, and lease expiry. Assert Base64
masks and untouched native labels alongside screenshots. If no session for a
provider exists, report its session-row gate as unverified rather than rendering
a replacement test row.

For the read-only integration checks, first select a separate test window with
the candidate launcher attached and open its actual native Agents settings or a
provider session row. Run `npm --prefix devin run build`, then
`AUTONOM_TEST_TARGET=<target> AUTONOM_TEST_ICON_PROVIDER=<provider-id> node --test --test-concurrency=1 dist/tests/integration/patches/status.js dist/tests/integration/patches/icons.js`
(set `AUTONOM_TEST_CDP_PORT` when using a debug port other than 9222). The status
check requires all seven installed hook groups and one visible native mode-switch
replacement; the icon check requires that provider's visible native icon, a
canonical Base64 dictionary entry, and unmasked labels or inputs. These tests
observe the selected context without navigating it. The icon check skips when
either required environment variable is absent; a missing native provider row
with both variables set fails and must be reported as an unverified live gate.

The existing Sessions performance check additionally requires an actual session
whose provider has registry icon metadata. Native Devin Local/OpenCode SVGs
alone do not exercise this patch. The benchmark counts a host whose computed
direct or `::before` mask matches an installed dictionary entry, so both the
inline React hosts and the `[data-acp-icon]:before` codicons count; visibility,
viewport, and the nonzero assertion are unchanged. If no eligible session
exists, report the unmet precondition; an Agents-page pass does not substitute
for session-list acceptance.
