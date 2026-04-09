# Cron jobs wiped during hand reactivation despite reassign_agent_jobs() being called

## Summary

In `activate_hand()` (kernel.rs ~line 3468), `kill_agent()` is called on the existing hand agent BEFORE the new agent is spawned. `kill_agent()` calls `cron_scheduler.remove_agent_jobs()` which deletes all the agent's cron jobs from memory AND persists `[]` to `cron_jobs.json`. The subsequent `reassign_agent_jobs()` call on line ~3496 is therefore always a no-op (`migrated = 0`), and the persisted jobs are lost.

This is the same class of issue as #461 ("cron jobs break after hand reactivation") which was supposed to be fixed by adding `reassign_agent_jobs()`, but the fix runs AFTER the destructive `kill_agent()` call, so it can never see any jobs to migrate.

## Repro

1. Activate a hand agent (`POST /api/hands/{id}/activate`).
2. Create a cron job for it (`POST /api/cron/jobs` with the agent_id).
3. Confirm `cron_jobs.json` contains the job and `/api/cron/jobs` lists it.
4. Restart the daemon (`docker restart`, or `openfang stop && openfang start`).
5. At boot, openfang re-activates the hand agent — which goes through `activate_hand()` → `kill_agent(old.id)` → `cron_scheduler.remove_agent_jobs(old.id)` → `persist()` writes `[]`.
6. The cron job is gone. `/api/cron/jobs` returns empty, `cron_jobs.json` is `[]`.

## Root cause

`crates/openfang-kernel/src/kernel.rs:3468-3502` (current `main`):

```rust
if let Some(old) = existing {
    info!(agent = %old.name, id = %old.id, "Removing existing hand agent for reactivation");
    let _ = self.kill_agent(old.id);  // ← removes ALL crons for old.id and persists []
}

let fixed_agent_id = AgentId::from_string(hand_id);
let agent_id = self.spawn_agent_with_parent(manifest, None, Some(fixed_agent_id))?;

// ...trigger restore (which works because triggers were `take`n into a local Vec earlier)...

// Migrate cron jobs from old agent to new agent so they survive restarts.
// Without this, persisted cron jobs would reference the stale old UUID
// and fail silently (issue #461).
if let Some(old_id) = old_agent_id {
    let migrated = self.cron_scheduler.reassign_agent_jobs(old_id, agent_id);
    // migrated is ALWAYS 0 here — kill_agent() above already wiped them
    if migrated > 0 {
        if let Err(e) = self.cron_scheduler.persist() {
            warn!("Failed to persist cron jobs after agent migration: {e}");
        }
    }
}
```

The triggers code (lines 3465-3467, 3479-3489) handles this correctly by `take`ing the triggers into a local `saved_triggers` Vec BEFORE calling `kill_agent()`, then restoring them AFTER the new agent is spawned. The cron code does not — it tries to migrate jobs from old to new in-place, but they've already been removed.

## Proposed fix

Mirror the trigger pattern for crons. Save the old agent's cron jobs into a local Vec before `kill_agent()`, then re-add them after `spawn_agent_with_parent()`. Patch:

```rust
let old_agent_id = existing.as_ref().map(|e| e.id);
let saved_triggers = old_agent_id
    .map(|id| self.triggers.take_agent_triggers(id))
    .unwrap_or_default();
// NEW: save crons before kill_agent destroys them
let saved_crons: Vec<openfang_types::scheduler::CronJob> = old_agent_id
    .map(|id| self.cron_scheduler.list_jobs(id))
    .unwrap_or_default();

if let Some(old) = existing {
    info!(agent = %old.name, id = %old.id, "Removing existing hand agent for reactivation");
    let _ = self.kill_agent(old.id);
}

let fixed_agent_id = AgentId::from_string(hand_id);
let agent_id = self.spawn_agent_with_parent(manifest, None, Some(fixed_agent_id))?;

// ...existing trigger restore...

// NEW: re-add the saved cron jobs against the new agent_id
// (which equals old.id when fixed_id is derived from hand_id, but be explicit)
if !saved_crons.is_empty() {
    let restored: usize = saved_crons.into_iter().filter_map(|mut job| {
        job.agent_id = agent_id;
        // Reset runtime state so jobs get a fresh start
        job.next_run = None;
        job.last_run = None;
        self.cron_scheduler.add_job(job, false).ok()
    }).count();
    if restored > 0 {
        info!(
            agent = %agent_id,
            restored,
            "Restored cron jobs after hand reactivation"
        );
        let _ = self.cron_scheduler.persist();
    }
}

// The existing reassign_agent_jobs() block can stay as a no-op safety net
// for the case where saved_crons was empty but reassignment is somehow needed.
// Or it can be removed since the new code subsumes it.
```

Bonus: the existing `reassign_agent_jobs()` block becomes dead code (jobs are always 0 now since kill removed them). It can be removed in the same PR or left as a defensive no-op.

## Impact

For users running hand agents with cron jobs (engagement monitoring, scheduled reports, periodic data sync, etc.), every daemon restart silently destroys all their cron jobs. There is no error message, no warning — `cron_jobs.json` is just rewritten as `[]`.

Workaround until fixed: recreate cron jobs via `POST /api/cron/jobs` after every restart, or stop using hand-style agents for anything involving crons.

## Environment

- openfang 0.5.5 (issue likely present in `main`/0.5.7 too — verified the code is unchanged in latest commits)
- Reproduced on Linux x86_64 with Docker

I'm happy to send a PR with the fix above. Let me know if you'd prefer a different approach (e.g., `kill_agent_keep_crons()` variant, or fixing it inside `kill_agent` itself by checking if a same-UUID respawn is imminent).
