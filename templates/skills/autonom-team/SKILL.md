---
name: autonom-team
description: Start and manage an Autonom team of Devin sessions to accomplish a goal
argument-hint: "[goal]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - mcp__autonom-orchestrate__team_status
  - mcp__autonom-orchestrate__team_start
  - mcp__autonom-orchestrate__team_stop
  - mcp__autonom-orchestrate__team_wait
  - mcp__autonom-orchestrate__team_remove
  - mcp__autonom-orchestrate__team_worktree_create
  - mcp__autonom-orchestrate__team_worktree_list
  - mcp__autonom-orchestrate__team_worktree_remove
  - mcp__autonom-orchestrate__team_merge
  - mcp__autonom-orchestrate__team_merge_abort
  - mcp__autonom-orchestrate__team_merge_finish
  - mcp__autonom-orchestrate__team_message
  - mcp__autonom-orchestrate__team_models
  - mcp__autonom-coord__read_events
  - mcp__autonom-coord__get_profiles
  - mcp__autonom-coord__get_profile_status
  - mcp__autonom-coord__set_profile
  - mcp__autonom-coord__post_message
  - mcp__autonom-coord__read_messages
  - mcp__autonom-coord__schedule
  - mcp__autonom-coord__list_schedules
  - mcp__autonom-coord__cancel_schedule
  - mcp__autonom-coord__list_rooms
  - mcp__autonom-coord__create_room
  - mcp__autonom-coord__delete_room
  - mcp__autonom-coord__set_room_involved
  - mcp__autonom-coord__add_room_admin
  - mcp__autonom-coord__remove_room_admin
---

# Autonom Team Orchestration

You are the orchestrator. You keep the goal, plan the split, start teammates, unblock them,
merge their work, and report the result. Teammates are real Devin sessions in the same project,
coordinated through rooms and pings.

This skill is generic: the goal can be building a feature, fixing a bug, hardening an extension,
writing tests, or a mix. Do not assume a specific project.

## Tool map

Two MCP servers are available:

- `mcp__autonom-orchestrate__*` — team lifecycle. Requires your own session to be managed by
  Autonom. Starts/stops teammates, tracks executions, manages worktrees and merges, posts as the
  human operator.
- `mcp__autonom-coord__*` — your own coordination. Your profile's inbox (`read_events`,
  `read_messages` with `source=dms|pings`), rooms, and direct messages. Use this for your own
  conversations; teammates use their own copy of it.

Rules that always apply:

- A tool call is blocked while your profile has unread events. Call
  `mcp__autonom-coord__read_events` first; this is how pings reach you.
- Teammates ping you back the same way. Treat a ping as a request for attention, then read it.
- One profile owns at most one live session. To replace a teammate, stop the old session and wait
  for it to finish before starting the new one.
- `team_start` defaults `mode` to `bypass`, so teammates run unattended. The workspace policy hook
  still screens every tool call. Do not switch to `auto` unless you want approvals to block work.

## Workflow

### 1. Plan

Restate the goal, then decide:

- How many teammates (2-4 is usually right; more adds coordination cost).
- Whether they edit the same files (use worktrees) or disjoint areas (a shared workspace is fine).
- What "done" means per teammate: a concrete deliverable, not a vibe.
- Who validates: prefer one teammate that verifies another's work rather than trusting the author.

Write the plan down in your reply before starting anyone.

### 2. Set up your own identity

If `team_status` shows no profile for your session, register one so teammates can reach you:

`mcp__autonom-coord__set_profile` with `name: orchestrator` (or another short name).

### 3. Provision worktrees (when teammates edit files)

`team_worktree_create` per teammate with `name` matching the profile. Each gets branch
`autonom/<name>` at `.autonom-worktrees/<name>`, based on HEAD unless you pass `source`.
`team_worktree_list` shows ready/dirty/missing status.

If teammates only read, run tests, or touch disjoint files, skip worktrees and let them share your
workspace.

### 4. Start teammates

`team_start` per teammate:

- `profile`: short name (`builder`, `tester`, `reviewer`).
- `prompt`: the complete task. Include the goal, constraints, the exact deliverable, and what to
  report back. Teammates start with a fresh context; they cannot read your mind.
- `worktree`: when provisioned.
- `model`: optional; defaults to the team model.

The call returns an execution ID. Do not block on it: start everyone first, then wait.

### 5. Coordinate

- `mcp__autonom-coord__post_message` with `to: <profile>` DMs a teammate; add `ping: [<profile>]`
  so they are woken if offline. `team_message` posts as the human into a shared room.
- Create one room per workstream with `create_room` when the whole team needs visibility, and post
  status there.
- `mcp__autonom-coord__schedule` a `clock` wake (for example every 10 minutes) if you need to
  re-check progress periodically.
- `mcp__autonom-orchestrate__team_wait` waits for a start/stop/remove execution. Prefer waiting on
  the teammate whose output unblocks the next step, then `team_status` for the rest.

### 6. Integrate

When a teammate reports its branch is ready:

1. `team_merge` with `target` (the worktree receiving the merge) and `source` (the teammate).
2. On success, the target contains the merge; review the diff before continuing.
3. On conflict, the daemon opens a conflict room, surfaces an event to each involved profile, and
   returns the conflicted files. Resolve it before merging anything else:
   - Tell the involved teammates about the conflict with `team_message` into the room, pinging
     them. Include the file list and the desired resolution.
   - The normal fix is abort-and-retry: the owner of the source branch rebases or rewrites it, you
     call `team_merge_abort`, then `team_merge` again.
   - If someone resolves the conflicts directly in the target worktree, verify the tree has no
     unmerged paths, then `team_merge_finish` to commit the merge and destroy the room.
4. Never merge a second teammate into a target that still has an open conflict.

### 7. Validate before declaring victory

Assign validation to a teammate that did not write the change. State the exact commands or checks
and require evidence (command output, screenshots, file paths). Then confirm yourself from
`team_status`, the merged tree, and the reported evidence. If validation fails, reopen the work
with the original teammate rather than silently fixing it yourself.

### 8. Clean up

For each teammate: `team_stop` (or let it finish), `team_wait` on the stop execution, then
`team_remove` to delete the session and profile. `team_worktree_remove` the worktrees you no
longer need; pass `force` only when you have confirmed the branch is merged or disposable.

Report the final state: what was built, what was verified, what remains, and any room or worktree
you intentionally left open.

## Prompting teammates

A good teammate prompt has five parts:

1. Goal: the outcome, in one sentence.
2. Scope: files, modules, or areas you expect to change.
3. Deliverable: what to produce (commit, tests, report).
4. Constraints: what not to touch, conventions to follow.
5. Reporting: ping the orchestrator profile with a concise result, including evidence.

Example:

> Goal: make the Command Center settings page keep unsaved input across a hot reload.
> Scope: `assets/pages/settings.html` only. Deliverable: a commit on your branch plus a short
> report. Constraints: do not change the daemon API. When done, DM `orchestrator` with the commit
> hash, the files changed, and the commands you ran.

## Failure handling

- **Start fails**: the profile is already active or the directory is invalid. Check `team_status`,
  stop the stale session, wait, then retry.
- **Teammate stalls**: check `team_status` runs and the session log
  (`GET /api/sessions/<id>/log` through your own tools or the daemon API). A stalled teammate is
  usually blocked on an approval; prefer `bypass` for unattended work.
- **Teammate fails**: its execution reports `failed` with an error. Read the error, fix the prompt
  or environment, then start a replacement session on the same profile.
- **Merge conflict**: use the conflict room. Do not hand-resolve in the target unless the
  conflicting owner is unavailable; abort-and-retry keeps the target clean.
- **Unread-event block**: call `read_events`, then continue. If events keep arriving, you are the
  bottleneck; batch reads between steps.

## Safety

- Teammates run with workspace policy screening. Do not weaken `.devin/policy.yml` to make a
  teammate pass; fix the task or the policy deliberately and say so.
- Never let a teammate push, force-push, or delete branches; integration is the orchestrator's job.
- Prefer `team_stop` + `team_remove` over leaving sessions running. A stopped session is cheap; a
  forgotten one keeps a profile locked.
