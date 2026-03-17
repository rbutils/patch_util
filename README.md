# PatchUtil

PatchUtil is a Ruby library and CLI for splitting one large patch into a sequence of smaller, reviewable patches. It is designed around an `inspect -> plan -> apply` workflow that works well for both humans and AI agents.

The main surface is the `split` subsystem:

- `split inspect` shows a patch with stable hunk and changed-line labels
- `split plan` turns those labels into named split chunks
- `split apply` materializes the saved plan as ordered patch files or rewritten commits

The `rewrite` subsystem is supporting machinery for harder git-history splits. It manages retained rewrite state, conflict recovery, and resume/restore flows after `split apply --rewrite` has started.

The API and CLI are still evolving and should be considered unstable until version 1.0.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "patch_util"
```

And then execute:

```sh
bundle install
```

If you want the gem installed directly:

```sh
gem install patch_util
```

For local development from this checkout:

```sh
bundle install
bundle exec rake spec
```

## Why PatchUtil

PatchUtil is built for cases where one diff or one commit mixes several independent intent units.

Typical examples:

- split a large refactor into reviewable commits
- separate rename/mode metadata from later content edits
- split one earlier git commit and replay descendants on top
- let an AI agent inspect a large patch, propose chunk boundaries, and then apply them deterministically

The project uses stable hunk labels (`a`, `b`, `c`) and changed-line labels (`a1`, `a2`, `b1`) so plans can stay textual and easy to generate.

## Split Workflow

The normal workflow is:

1. inspect the commit or patch
2. choose selectors for named chunks
3. persist the plan
4. apply the plan

### Inspect

Choose source options based on what you are splitting:

- use `--repo` plus `--commit` for a git-backed split workflow
- use `--patch` (and usually `--plan`) for a standalone patch-file workflow
- these flags are contextual source selectors, not mandatory boilerplate on every invocation

Inspect a git commit:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2
```

Inspect a patch file:

```sh
patch_util split inspect --patch sample.diff --plan sample.plan.json
```

The output labels hunks and changed lines so you can refer to them later:

- whole hunks: `a`, `b`, `c`
- whole-hunk ranges: `a-c`, `z-ab`
- single changed lines: `a1`, `a2`
- ranges inside one hunk: `a1-a4`

Default inspect output is the full annotated diff because it is the authoritative planning surface.

### Compact Inspect For Agents

For large commits, especially vendor-heavy ones, compact inspect gives a skim-friendly overview:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2 --compact
```

Compact mode keeps the same labels but adds a layered summary:

- compact legend
- file index
- per-file and per-hunk counts
- largest-first index ordering
- compact hunk summaries in original diff order

You can then drill into only the hunks that matter:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2 --compact --expand a-c,br
```

That keeps the compact skim for the whole patch while expanding only the selected hunks to full annotated row bodies.

`--expand` is intentionally narrow:

- it only works together with `--compact`
- it accepts whole-hunk labels and hunk ranges such as `a,b,br` or `a-c`
- it does not accept changed-line selectors such as `a1-a4`

Recommended agent loop for very large commits:

1. start with full `split inspect` if the patch still looks manageable
2. switch to `--compact` when the patch is too noisy to scan directly
3. use `--expand` only on the few hunks that look relevant
4. move to `split plan` once the chunk boundaries are clear

### Plan

Create a split plan from named chunks and selectors:

```sh
patch_util split plan \
  --repo /path/to/repo \
  --commit HEAD~2 \
  "rename and setup" "a-b" \
  "logic change" "c1-c4,d" \
  "leftovers"
```

Selectors can combine whole hunks and changed-line ranges:

```text
a-c,e1-e4,e6
```

Rules:

- selecting a whole hunk and partial lines from that same hunk is an error
- overlapping selections across chunks are an error
- if changed lines are left unassigned, planning fails unless you declare a leftovers chunk
- leftovers are declared as the final positional chunk name, with no selector text after it

If you do not specify a leftovers chunk, PatchUtil fails closed instead of silently dropping the unassigned changes. That is deliberate: omitted leftovers would otherwise mean those changed lines disappear from the emitted patches or rewritten history.

Today, PatchUtil treats that as a safety stop, even though removal might sometimes be the right outcome. In those cases, the current workflow is to re-plan explicitly rather than relying on implicit omission.

Example with leftovers:

```sh
patch_util split plan \
  --repo /path/to/repo \
  --commit HEAD~2 \
  "rename metadata" "a" \
  "core logic" "b1-b5,c-d" \
  "leftovers"
```

Inside a git repository, plans default to `.git/patch_util/plans.json`.

### Apply

Materialize the saved plan as patch files:

```sh
patch_util split apply \
  --patch sample.diff \
  --plan sample.plan.json \
  --output-dir out
```

Use this mode when you want PatchUtil to emit patch files only, without changing git history.

Apply a saved git-backed plan by rewriting an earlier commit:

```sh
patch_util split apply \
  --repo /path/to/repo \
  --commit HEAD~2 \
  --rewrite
```

Use `--rewrite` only when the split should become real replacement commits inside the repository history. In other words:

- without `--rewrite`, PatchUtil emits patch files
- with `--rewrite`, PatchUtil replaces the targeted commit with one commit per chunk and then replays later descendants on top

When rewriting history, PatchUtil:

- creates one replacement commit per named chunk
- preserves the original split commit's author, committer, body, and trailers
- appends `Split-from:` and `Original-subject:` metadata
- replays later descendants on top
- records a backup ref under `refs/patch_util-backups/...`

Current rewrite guardrails:

- merge commits are rejected as split targets
- descendant replay is only supported on linear history; replay ranges containing merge commits fail up front

## Rewrite Subsystem

The top-level `rewrite` commands are mainly recovery and inspection tools for difficult history rewrites.

You normally start from `split apply --rewrite`, and only use `rewrite ...` if the rewrite needs help afterward.

For agents, this boundary matters:

- prefer `split inspect`, `split plan`, and `split apply` in normal explanations
- treat `rewrite ...` as recovery/support tooling, not the default planning interface
- surface `rewrite status`, `rewrite conflicts`, `rewrite continue`, and `rewrite restore` after a rewrite has already started or failed

Examples:

```sh
patch_util rewrite status
patch_util rewrite conflicts
patch_util rewrite continue
patch_util rewrite restore
```

This layer exists so harder split rewrites can be resumed, inspected, or restored without mixing that recovery flow into the main `split` planning UX.

## After PatchUtil

PatchUtil handles the split itself. After that, you may still want ordinary git history-polish steps outside PatchUtil.

Human-driven follow-up:

- use `git rebase -i` later if you want to combine adjacent split commits, reorder them, or reword commit messages

Agent-friendly or non-TTY follow-up:

- use non-interactive git commands such as `git commit --amend -m ...`, `git reset --soft HEAD~2 && git commit ...`, or scripted cherry-pick/replay flows when you need similar cleanup without an interactive editor

Those steps are outside PatchUtil's command surface, but they fit naturally after `split apply --rewrite` has produced the first-pass split history.

## Agent Skill

PatchUtil is intended to be usable by AI agents. This repository includes a `SKILL.md` focused on the `split` workflow.

OpenCode one-liner install:

```sh
mkdir -p ~/.config/opencode/skills/patch_util && curl -fsSL https://raw.githubusercontent.com/rbutils/patch_util/master/SKILL.md -o ~/.config/opencode/skills/patch_util/SKILL.md
```

After that, OpenCode can discover the skill from the standard global skills directory.

## Development

After checking out the repo, run:

```sh
bundle install
bundle exec rake spec
```

You can run the executable directly from the checkout:

```sh
bundle exec exe/patch_util version
bundle exec exe/patch_util split help
bundle exec exe/patch_util rewrite help
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rbutils/patch_util.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
