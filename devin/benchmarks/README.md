# Desktop performance checks

These benchmarks require a real, logged-in Desktop with the production launcher.
Start it with `devin-desktop --debug`. Keep the communication window untouched.
Build the checkout with `npm --prefix devin run build` before measuring.

Open a separate native window and observe its target, DOM, shell, runtime, and
visible sidebar readiness (milliseconds since the normal window request):

```sh
node dist/benchmarks/startup.js /home/cet/Repos/autonom /tmp/autonom-startup.json
```

The benchmark operates the real Autonom control as soon as it is visible. It
leaves its test window open. It measures a new window in a running browser;
record cold browser startup separately from the launch command and launcher log.
Capture logs from `devin-desktop --debug` for cumulative native-service capture
phases (`debugger-ready`, `manifest-captured`, `services-captured`).

On the new window, select the real Sessions row and leave provider icons visible.
Use its exact target ID to record 30 paired shell update/heartbeat samples:

```sh
node dist/benchmarks/sidebar.js TARGET_ID > /tmp/autonom-sidebar.json
AUTONOM_TEST_TARGET=TARGET_ID npm --prefix devin run test:integration
```

The sidebar benchmark records raw samples, medians, p95/max, DOM/candidate counts,
visible mask counts, and the optimized runtime's scan counters. It calls the
production shell against its existing DOM and stylesheet. No fake UI or React
state is injected. Idle calls must leave scan counters unchanged; measurements
of changed DOM and initial icon paint are separate from this idle benchmark.
The integration checks operate only that explicitly selected window. Without a
target, live checks are skipped and the installed build check still runs.

Compare repeated runs on the same build, catalogs, workspace, and visible view.
Retain raw JSON, launcher output, screenshots, build hashes, and target IDs.
Report differences in DOM size or session state with the timings. Do not use a
unit test or an idle timing as evidence of startup or native UI compatibility.
