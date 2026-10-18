# Workspace mode switch

`patches/mode-switch.ts` hooks the pinned `.agent-editor-switch`. It hides the
native presentation with an owned CSS declaration and inserts one custom group
with Autonom, Devin Cloud, and Editor controls. `mode-icons.ts` supplies the marks.
The original Agent/Editor handlers still perform workbench transitions; forwarding
briefly reveals the native switch, then restores its exact display declaration.

The custom controls are outside the titlebar drag region through the scoped
`assets/ui.css` rules. A native transition can remount the switch; reconciliation
restores the old root and binds the current native buttons. Delayed transitions
carry a sequence token and cannot reveal the sidebar after a newer selection or
a disposed runtime. An explicit Autonom click reveals a hidden Agent sidebar
after the native transition settles.

The patch owns its style element, inserted controls, observer, timers and
30-second lease. It composes the independently named ACP icon patch. Disposal,
hot replacement and lease expiry restore the original roots and remove owned
nodes. A native replacement is preserved instead of overwritten.

Live acceptance requires physical CDP pointer clicks on the visible controls,
three Autonom/Cloud/Editor cycles, hidden-sidebar selection, and remount/hot/
teardown checks. Scripted `.click()` alone does not establish pointer behavior.
