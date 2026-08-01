# GitLab merge request watch verification

Empirical record for the merge request watch on GitLab, alongside the existing GitHub watch.
The current API and poll commands below were run on 2026-08-01 and their bounded output is reproduced exactly.
The provider-tag migration and missing-tool evidence retained later in this record was run on 2026-07-21.

## Versions

```
$ glab --version
glab 1.111.0 (23893459)

$ /bin/bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
```

## The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

## Why the host is data rather than a constant

GitLab runs mostly on self-hosted instances, so a merge request can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
The tests cover arbitrary validated hosts and nested project paths without hard-coding `gitlab.com` as the provider host.

## The host-bound API provides all actionable states

The watcher runs without a current Git repository, so it addresses the merge request through `glab api` with a URL-encoded project path and the validated host.
GitLab monitoring requires `jq`, and arming refuses when it is missing.
One API response then classifies merge, close, conflict, and failed-pipeline states without parsing rendered text.
The query asks GitLab to refresh merge status, but treats every missing, malformed, or unreadable field as silence rather than inventing an event.

The two public fixture merge requests returned these bounded shapes:

```sh
$ glab api 'projects/KarotKris%2Fgitlab-merge-watch-fixture/merge_requests/1?with_merge_status_recheck=true' --hostname gitlab.com \
    | jq -c '{iid,state,detailed_merge_status,has_conflicts,head_pipeline_status:(.head_pipeline.status // null)}'
{"iid":1,"state":"merged","detailed_merge_status":"not_open","has_conflicts":false,"head_pipeline_status":null}

$ glab api 'projects/KarotKris%2Fgitlab-merge-watch-fixture/merge_requests/2?with_merge_status_recheck=true' --hostname gitlab.com \
    | jq -c '{iid,state,detailed_merge_status,has_conflicts,head_pipeline_status:(.head_pipeline.status // null)}'
{"iid":2,"state":"opened","detailed_merge_status":"mergeable","has_conflicts":false,"head_pipeline_status":null}
```

## End to end: arming and polling a real merge request

Three tasks were armed, two against the fixture and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

The provenance record for the non-default host, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged fixture merge request produces exactly one `merged` line.
The open green merge request produces nothing, and the unreachable placeholder host produces nothing rather than a false event.
The close, conflict, failed-pipeline, malformed-output, and repeat-event matrix is hermetic in `tests/fm-pr-check-security.test.sh`.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1x.check.sh
merged
```

## A missing poll tool produces no wake, never a false merge

The GitLab poll is silent on every error by design, so a missing `glab` or `jq` would otherwise be indistinguishable from a merge request that never changes.
With `glab` removed from `PATH`, the poll stays silent even for the merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire.
The `noglab` fixture below retains `jq` and removes only `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e6 https://github.com/kunchenguid/firstmate/pull/750
armed: state/e6.check.sh
```

## Upgrade path from an existing armed watch

The stored record gained the provider tag, so its version moved to `fm-pr-poll-registration-v2` and a record written by the previous release no longer parses.
The existing non-executing migration handles that: it never runs the old artifact, and rebuilds the poll from the task's recorded pull request URL.
Starting from a poll armed exactly as the previous release wrote it:

```
$ head -1 state/t1.pr-poll-registration
fm-pr-poll-registration-v1
$ fm-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home
$ head -2 state/t1.pr-poll-registration
fm-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

The rebuilt poll works, verified against a pull request that is genuinely merged:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

No armed watch is lost by upgrading.

## What this change does not cover

`bin/fm-pr-merge.sh` still addresses GitHub only, by owner and repository.
It refuses a GitLab merge request URL rather than sending it to the wrong forge, so merging a merge request stays a deliberate manual step until merge parity lands separately.

A GitLab task still records no `pr_head=` because extending head metadata is separate from state monitoring.
Both consumers already treat it as optional: `bin/fm-teardown.sh` reads the head from the forge at teardown rather than from metadata and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.
