# VM state persistence

Keeps a 6-hour GitHub Actions Windows VM alive across runs: whatever was on
the machine when it expired is put back onto the next one, so a project that
outlives the timeout resumes instead of starting over.

## What gets saved

| pack | contents | when |
| --- | --- | --- |
| `-work.7z.*` | `C:\Users\rdpuser` verbatim - projects, documents, downloads, application settings, `NTUSER.DAT`, hidden and system files | every snapshot |
| `-sys.7z.*` | `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData` **as a delta against the pristine runner image** - only what you installed or changed | every snapshot |
| `-meta.7z` | registry hives, the RDP user's personal hive, custom scheduled tasks, service start types, machine environment variables, installed-application inventory | every snapshot |

Storage is a GitHub **Release** tagged `vm-state`, not an artifact: the free
plan only includes 500 MB of artifact storage, while releases have no total
size or bandwidth limit (2 GiB per asset, up to 1000 assets).

### The baseline

The runner image ships ~120 GB (Visual Studio, Android SDK, ...). Storing that
would be impossible, so `baseline.ps1` records a manifest of a *pristine*
machine once, and `snapshot.ps1` only keeps files that differ from it.

**The baseline must be captured before anything is restored or installed.**
If it were taken afterwards your own state would be baked into it and the
delta would silently stop capturing new applications. Rebuild it with
`-Force` after GitHub rolls a new runner image.

## Files

| file | role |
| --- | --- |
| `lib.ps1` | configuration, file enumeration, 7-Zip helpers, release client |
| `baseline.ps1` | capture / rebuild the pristine-image manifest |
| `restore.ps1` | put the previous VM onto this one |
| `snapshot.ps1` | pack everything and publish it |
| `continue.ps1` | decide whether the next VM starts |
| `smoke-test.ps1` | offline roundtrip test - run this before pushing changes |

## Repository variables

Set these under *Settings -> Secrets and variables -> Variables*:

| variable | default | meaning |
| --- | --- | --- |
| `VM_CONTINUE` | *(unset = continue)* | set to `false` to **stop the chain for good** |
| `VM_MAX_CHAIN` | `9999` | safety ceiling on consecutive runs |
| `SNAPSHOT_INTERVAL` | `20` | minutes between snapshots |
| `SNAPSHOT_STOP_AFTER` | `330` | stop snapshotting at this minute of the session |
| `CONTINUE_AT` | `340` | queue the next VM at this minute |
| `LOOP_END` | `348` | end the keep-alive loop at this minute |

Snapshots deliberately stop before the 360-minute job timeout so the last one
is guaranteed room to finish, and the next run is queued while the current one
is still alive - a `concurrency` group holds it, so there is no dead gap.

## Stopping

The chain is unlimited by design. To stop it:

```
gh variable set VM_CONTINUE --body false
```

or set it in the web UI. A run that fails during setup also halts the chain on
its own, so a broken configuration is never retried forever.

## Known limits

- **Persistence is not unlimited runtime.** A run still ends at 6 hours. Work
  done after the last snapshot (up to `SNAPSHOT_INTERVAL` minutes) is lost.
- `C:\Windows` itself is not captured - it comes fresh from GitHub's image,
  which is stable anyway. Everything else is.
- A running service's *state* is not captured, only its start type. The
  keep-alive loop re-applies the RDP and performance tuning on every run.
- Files locked during a snapshot (for example a loaded registry hive) are
  skipped with a warning rather than failing the whole snapshot.
