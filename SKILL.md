---
name: patch_util
description: Split large diffs or commits into smaller reviewable patches with an inspect -> plan -> apply workflow. Prefer the split subsystem; use rewrite only for retained rewrite recovery and harder history-rewrite cases.
license: MIT
---

# PatchUtil Skill

Use this skill when you need to break one large git commit or diff into smaller reviewable units.

## When To Use It

- a git commit should be split into several commits
- a patch file needs the same inspect -> plan -> apply treatment outside a repository
- you need a stable textual selector language for agent-planned patch splits
- a large commit is easier to navigate in compact inspect mode before choosing split boundaries

## Preferred Workflow

Default to the `split` subsystem:

1. `split inspect` on the git commit you want to split; add `--compact` first for large or noisy commits
2. use targeted `--expand` on interesting hunks, then build a `split plan` against that same source
3. when partial selectors are involved, prefer `split apply --output-dir ...` first and read the emitted patch text before rewriting history
4. use `split apply --rewrite` only after the emitted patches look structurally correct and the split should become real replacement commits

For git rewrite workflows, surface these limits early:

- merge commits are not supported as split targets
- descendant replay ranges containing merge commits are rejected up front

Source selectors are contextual:

- use `--repo` with `--commit` for the primary git-backed workflow
- use `--patch` for standalone diff files when there is no repository-backed source
- `--repo` and `--commit` are optional source selectors, not mandatory boilerplate
- these flags are not all required at once; they describe which source PatchUtil should inspect or apply

Treat the top-level `rewrite` subsystem as advanced recovery machinery for `split apply --rewrite`, not as the first thing to expose to users.

## Core Commands

Primary git-backed inspect:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2
```

Compact inspect for a large git commit:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2 --compact
```

Compact inspect with targeted drill-down:

```sh
patch_util split inspect --repo /path/to/repo --commit HEAD~2 --compact --expand a-c,br
```

Git-backed planning:

```sh
patch_util split plan \
  --repo /path/to/repo \
  --commit HEAD~2 \
  "first chunk" "a-c" \
  "second chunk" "d1-d4,e" \
  "leftovers"
```

Use `--expand` only with `--compact`, and only with whole-hunk labels or hunk ranges.

Git-backed apply by rewriting the original history:

```sh
patch_util split apply \
  --repo /path/to/repo \
  --commit HEAD~2 \
  --rewrite
```

Use `--rewrite` only when the result should become real replacement commits in repository history. If you only want emitted patch files, use `split apply` without `--rewrite` and provide `--output-dir` instead.

Patch-file inspect remains available when there is no repo-backed source:

```sh
patch_util split inspect --patch sample.diff --plan sample.plan.json
```

Patch-file apply remains available when you want emitted patch files instead of history rewrite:

```sh
patch_util split apply --patch sample.diff --plan sample.plan.json --output-dir out
```

## Selector Rules

- whole hunks use labels like `a`, `b`, `c`
- whole-hunk ranges use labels like `a-c` or `z-ab`
- changed lines use labels like `a1`, `a2`, `b1`
- changed-line labels enumerate displayed changed rows in hunk order, including both removed (`-`) and added (`+`) rows
- ranges must stay inside one hunk, for example `a1-a4`
- do not mix whole-hunk and partial selection for the same hunk in one plan
- if anything is intentionally left unassigned, add a leftovers chunk name as the final positional argument to `split plan`

**Warning:** partial line selectors are text-row selectors, not AST-aware or syntax-aware edits. Selecting only the "new logical lines" from a replacement does not automatically remove the old ones.

For replacement hunks, especially in block-structured code, prefer selecting the full paired old+new replacement span. If a hunk touches block delimiters, method headers, `let` / `it` declarations, or moved setup code, selecting only added rows can leave duplicate lines behind and break syntax.

If no leftovers chunk is declared, PatchUtil fails instead of silently removing unassigned changes. That fail-closed behavior is deliberate: implicit omission would otherwise drop those changes from the output. If removal is actually intended, PatchUtil currently expects a more explicit re-plan rather than treating missing leftovers as permission to delete.

## Mixed Replacement Example

Suppose compact inspect shows one Ruby replacement hunk where an example declaration changes:

```diff
-it 'uses old setup' do
+let(:user) { build(:user) }
+it 'uses new setup' do
   run_example
 end
```

The unsafe plan is to select only the added rows, such as `a2-a3`. That keeps the old `it ... do` line and adds the new `let` / `it` lines, which can leave duplicated declarations or broken block structure.

The safe plan is to select the full replacement span that covers both the removed and added rows, for example `a1-a3`, then emit patch files first and read the resulting patch text before any `--rewrite` step.

## Agent Guidance

- start with git-backed `split inspect --repo ... --commit ...` unless the work is explicitly patch-file-only
- use `--compact` for large or noisy commits
- use `--expand` only after compact inspect has identified the interesting hunks
- keep `--expand` inputs at whole-hunk labels or hunk ranges only; changed-line selectors belong to `split plan`, not to compact drill-down
- think in syntactic units, not only semantic intent; for mixed replacements, select the full replacement span when structure matters
- treat `split apply --output-dir` plus emitted-patch review as the safe default before `--rewrite` when partial selectors are involved
- use `patch_util` to isolate cosmetic-only hunks or replacement spans into their own chunk so they can be reviewed, kept separate, or intentionally dropped after inspection
- propose chunk names based on reviewable intent, not file count alone
- preserve rename/mode/file-operation intent as first-class patch units when present
- prefer `split` language in explanations; mention `rewrite` only when recovery or history replay becomes relevant
- surface `rewrite` commands only after `split apply --rewrite` has started or failed

## Cosmetic Changes

When the goal is to remove cosmetic churn from a commit, `patch_util` helps by turning style-only hunks or replacement spans into explicit chunks:

1. inspect the commit and identify cosmetic-only hunks or mixed hunks with cosmetic replacement spans
2. plan cosmetic chunks separately from functional chunks
3. emit patch files first and read them to confirm the cosmetic chunk is actually cosmetic
4. keep that chunk as a separate reviewable commit, or omit/re-plan it intentionally if the cosmetic change should not survive

This is usually safer than manually editing a large original diff because the split stays explicit and reviewable.

## Rewrite Notes

If `split apply --rewrite` hits trouble, the retained rewrite commands are available:

- `rewrite status`
- `rewrite conflicts`
- `rewrite continue`
- `rewrite restore`

These are support tools for difficult rewrite cases, not the main planning interface.

## After The Split

PatchUtil's job is to produce the split cleanly. After that, normal git tools may still be useful.

- a human may use `git rebase -i` later to combine split commits, reorder them, or reword commit messages
- agents should prefer non-interactive follow-up commands such as `git commit --amend -m ...`, `git reset --soft HEAD~2 && git commit ...`, or scripted cherry-pick/replay flows instead of assuming an interactive TTY editor
- those follow-up git steps are outside PatchUtil itself, but they are normal after `split apply --rewrite` has created the first-pass split history

## Installation

If `patch_util` is not available on the machine yet, install the gem first:

```sh
gem install patch_util
```

Agents should do that whenever they intend to use the tool and the command is not available.

OpenCode global install:

```sh
mkdir -p ~/.config/opencode/skills/patch_util && curl -fsSL https://raw.githubusercontent.com/rbutils/patch_util/master/SKILL.md -o ~/.config/opencode/skills/patch_util/SKILL.md
```

Repo-local install:

```sh
mkdir -p .opencode/skills/patch_util && cp SKILL.md .opencode/skills/patch_util/SKILL.md
```
