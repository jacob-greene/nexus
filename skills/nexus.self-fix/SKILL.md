---
description: "Fixing the nexus itself — orchestrator, watcher, monitor scripts, skills, BOT_ADMIN_GUIDE. Pre-flight gate (freshness + substantiation + scope) before filing on <your-org>/nexus-code. Covers cross-fork ping discovery and (future) `ng propagate` for fork-fan-out."
---

# nexus.self-fix — bug-fixing the nexus and propagating across forks

TRIGGER when: agent is about to file an issue on
`<your-org>/nexus-code` or propose a nexus-self fix; agent is editing
files under `monitor/`, `skills/`, or the workspace `CLAUDE.md`;
agent is investigating a nexus-infra bug (watcher silently dropping
deliveries, eligibility filter misclassifying, `ng` verb
misbehaving); agent needs to propagate a nexus-internals fix to
sibling fork repos.

This skill is **nexus-self-only**. Project agents (kompot,
perturb-bench, fig4-subtle-de, etc.) doing GitHub writes against
their own work should rely on `nexus.bot` instead — cross-fork
discovery and propagation are nexus-bug-fix concerns, not general
GitHub-write concerns.

## Before filing an issue or proposing a fix

Self-improvement is high-leverage but easy to misfire — a
mis-scoped issue or a stale-checkout repro burns the operator's
triage budget and pollutes the tracker. Run these five checks
before opening an issue on `<your-org>/nexus-code` or authoring a
self-fix PR.

1. **Pull before you claim.** Sync the clone you're diagnosing
   from to the remote's **default branch**, then cite the SHA
   (`git rev-parse HEAD`) in the issue body. Resolve that
   branch — don't hard-code it. This skill ships to every
   operator's nexus and forks differ: most run `main`, some run
   a `dev` integration branch.

   ```bash
   BASE=$(git ls-remote --symref origin HEAD \
            | awk '/^ref:/ {sub("refs/heads/","",$2); print $2}')
   BASE=${BASE:-main}                    # fallback
   git fetch origin
   git merge --no-edit origin/"$BASE"
   ```

   Use `git ls-remote --symref`, **not** `git symbolic-ref
   refs/remotes/origin/HEAD` — the latter fails with *"not a
   symbolic ref"* on any clone or worktree where `git remote
   set-head` was never run, which is the usual case.

   **Merge; don't `--ff-only` or `--rebase`.** A clone that
   adopted a fork carries local-only commits — resolved template
   placeholders, operator-specific doc substitutions — that are
   deliberately never pushed. Its local default branch has
   therefore diverged **by construction** and can never
   fast-forward, so `git pull --ff-only` fails outright and
   `--rebase` would try to replay those local-only commits onto
   the remote. `git merge --no-edit` is the correct form, and
   the local default branch must never be pushed.

   A repro against a stale checkout proves nothing about
   current behavior — "filed against already-fixed code" is a
   recurring false-positive when an agent's clone lags the
   default branch.

2. **Substantiate the repro.** The issue body must carry:
   - Exact command(s), copy-pasteable.
   - Expected vs observed output as literal bytes, not
     paraphrase.
   - The SHA the repro ran against.
   - The file and line in nexus-code identified as
     responsible. Can't point to the code? The issue is not
     ready — keep investigating.

3. **Scope gate — is this nexus-specific?** Apply the mental
   test: *Would the same symptom occur in a clean shell with
   no nexus involvement?* If yes, the venue is the upstream
   project, not nexus-code. Common false positives that have
   landed as nexus-code issues and shouldn't have:

   | Upstream surface | Symptoms misread as nexus-bugs |
   |---|---|
   | Claude Code Bash tool | cwd persistence between calls, pane render, autosuggest, `settings.json` semantics |
   | `gh` CLI version drift | `gh 1.13.0` (base image) missing flags / different error messages than `gh 2.x` |
   | tmux platform quirks | window-name parsing, `remain-on-exit`, `automatic-rename` interactions |
   | Anthropic API behavior | rate limits, token counting, prompt cache hits, cache TTL |
   | Linux kernel | Landlock ABI, user namespaces, seccomp filters |

   If upstream is at fault: file there (Anthropic, `cli/cli`,
   `tmux/tmux`, the relevant kernel surface), or document the
   host-side workaround on the operator's instance — **don't**
   absorb into nexus-code core docs or the auto-injected
   worker floor. If you genuinely believe nexus-code's
   *integration with* the upstream tool is wrong (the wrapper
   carries an avoidable error path, the watcher misuses an
   API), the issue body must make the nexus-specific dimension
   explicit and substantiate it on its own merits.

4. **Read the relevant docs first.** Grep `docs/`,
   `monitor/README.md`, `skills/`, `monitor/agent-prompt.md`,
   and `CLAUDE.md` for existing coverage before claiming a
   feature is missing or a knob doesn't work. Cite the doc you
   checked in the issue body. Coupled with check 1, this
   catches the stale-checkout-against-recently-added-feature
   failure mode.

5. **Sweep the tracker in every state, and read closed bodies.**
   `gh issue list --search` returns OPEN issues only, so a closed
   issue holding your defect stays invisible. Pass `--state all`.
   The REST search covers every state by default.

   ```bash
   gh issue list --repo <owner>/<repo> --search "<terms>" --state all
   gh api -X GET search/issues -f q='repo:<owner>/<repo> <terms>'
   ```

   Confirm the query finds a hit you already know. An empty
   result reads the same whether the tracker is clean or your
   filter hid the match.

   **Read the bodies, not the titles.** A title names the primary
   defect only. A secondary defect in the body survives the close
   and is invisible to a title scan.

   A close is not a ruling. Read the closing comment and test it
   against source. On this nexus, eleven issues closed inside 102
   seconds in one bulk action. Four closing comments said "Nothing
   is lost by closing this". For all four it was false. Every one
   of those four bodies carried a defect that the close did not
   map onto the surviving issue.

   **The unmapped defect is a different one in each case.** One
   mechanism does not explain a set of closes. Check each body on
   its own. The *over-limit row* here is the watcher state row
   that holds emits to the orchestrator while a pane reads
   rate-limited.

   | Issue | Defect the close left unmapped |
   |---|---|
   | `#26` | Its "Defect B": the over-limit row is keyed by role, so a rotation does not clear it |
   | `#41` | The same role-keyed row, under its "Why it is worse than it looks" heading |
   | `#30` | Its first enumerated defect: the banner is re-read from stale scrollback |
   | `#84` | Its second, separately headed defect: the latch re-arms off the visible pane |

   `#30` is the one that punishes a fast read. Its Summary
   mentions the role-keyed row in a single line. The two defects
   it enumerates are different ones: the stale-scrollback re-arm,
   and a bare clock time resolved forward. Count what a body
   enumerates, not what it mentions in passing.

   `#84` is the one that punishes a fast count. Its second defect
   carries its own `##` heading, so no reading of the body can
   miss it. The close still mapped only the first. A defect can be
   impossible to overlook and still go unmapped, because mapping
   is a separate act from reading.

   **Say what a live mechanism now costs.** "Still live" alone is
   true and incomplete. The role-keyed row is live, and was
   refiled. But the merged fix bounds the hold three independent
   ways, so its worst consequence fell from about 6.5 hours of
   orchestrator blindness to minutes. The re-arm defect behind
   `#30` and `#84` is also live. It was not refiled, for two
   reasons: an open issue already names it, and the source
   documents its consequence as a bounded residual. A refile needs
   a live mechanism, no home issue, *and* a consequence the source
   does not already accept.

Each check is a verifiable action (run the command, paste the
SHA, name the file). Pass all five before opening the issue or
the PR — not posture, output.

## Closing an issue — enumerate what the close settles

The same defect seen from the filing side. A multi-defect body
gets closed on its primary defect, and the secondary defects
vanish, because nothing points at them any more.

Before you close, list the distinct defects in the body. For each
one, say where it now lives: fixed by a named PR, or carried over
to the surviving issue. Never write "nothing is lost" unless you
checked every defect in the body.

Carrying over is the step that is skipped. One good close in the
bulk action above found a symptom missing from the surviving
issue, added it there, and said so. That is the shape to copy.

## Opening the self-fix PR — base the default branch, gated merge

Once the five checks pass and you have a fix, open the PR
against the **remote's default branch** — the `$BASE` resolved
in check 1 — never a branch you assumed:

```bash
ng pr create --base "$BASE" …        # or: gh pr create --base "$BASE" …
```

Guessing the base is not a cosmetic error. `--base dev` against
a fork that has no `dev` branch makes the PR **unopenable**, and
every agent that follows the instruction burns a cycle
rediscovering that. Confirm the branch exists before you rely on
it: `git ls-remote --heads origin`.

On a fork whose default is an integration branch (`dev`, and
`main` promoted from it on a separate operator-gated soak),
basing on the default branch is also what keeps a self-fix from
jumping the integration step. Either way the rule is the same —
resolve, don't assume.

**Do NOT merge your own self-fix PR.** The merge is gated, not
autonomous. After opening the PR, wait for an
explicit OK from the current code owner OR a direct
confirmation from the operator before merging. A self-fix
touches the very machinery every operator runs — letting the
authoring agent self-merge removes the one human checkpoint
that catches a plausible-but-wrong infra change before it fans
out. Open it, link it, and stop; the code owner or operator
pulls the trigger.

## Cross-fork pings (`nexus-fork` topic) — legacy

> **Heads-up — partly obsolete after the asset-repo cutover.** With
> the canonical implementation living at `<your-org>/nexus-code` (every
> operator clones the same repo; `git pull` fans out updates), most
> "propagate this fix to sibling forks" cases now collapse to a
> single PR on `<your-org>/nexus-code`. The topic-discovery path below
> applies to legacy forks that still hold their own copy of the
> implementation, and to per-operator asset+issue repos when an
> operator-specific fix needs sibling-operator awareness.

When a fix in one nexus fork should be propagated to siblings (a bug
that affects every fork's watcher, a doc correction in a shared
skill), enumerate live forks via the `nexus-fork` GitHub topic that
each fork maintainer tags their repo with:

```bash
gh search repos topic:nexus-fork org:<your-org> --json fullName,description
```

This uses **bare `gh`** under the caller's user PAT, not the bot
token: bot installation tokens are scoped per-fork and don't see
sibling forks they aren't installed on. Topic search is read-only
metadata and works for any logged-in user.

For each fork the fix applies to, ping the maintainer in the PR or
issue body:

```
cc @<maintainer> (`<owner>/<repo>`)
```

Listing the repo in backticks alongside the mention disambiguates
multi-fork pings and avoids GitHub's `#N` auto-link surprises if a
number ever creeps in. New forks must run
`gh repo edit <your-org>/<user>-nexus --add-topic nexus-fork` once to
appear in the lookup; see `monitor/BOT_ADMIN_GUIDE.md` step 14.

## Cross-fork PR body convention (for the future `ng propagate` verb)

When opening a cross-fork PR via `ng propagate <PR>`, the PR body on
each target fork should differ from the upstream PR's body. Lead with
a simple, non-technical explanation aimed at the fork's maintainer
(who may not be deep in nexus internals):

```
## What this does for your fork

[1-2 plain-English sentences: this PR brings <fix> from upstream nexus.
 Merging it means <user-visible consequence>. No action required after
 merge beyond the standard `git pull` — the version-aware watcher
 self-restarts onto the new code.]

## Upstream PR

Full technical detail and discussion: <upstream PR URL>.

## What changed (one-line summary per file)

[terse table of file paths + change kind, no implementation depth]
```

Tone: "what merging this does for you" first; "how it works" linked,
not embedded. The upstream PR body is for nexus developers; the
cross-fork PR body is for fork maintainers who want the fix without
becoming nexus-internals experts.

The `ng propagate` verb does not exist yet — this convention is
documented now so the eventual implementation has a target.

## See Also

- `nexus.bot` — general GitHub-write rules (bot identity, `ng` verb
  table, the wiki-upload rule). All cross-fork writes still flow
  through the bot-identity discipline documented there.
- `nexus.report` — the `## Infrastructure Issues` section is where
  nexus-bug findings get recorded for the periodic infra meta-review.
- `nexus.infra-review` — the periodic review that turns infra-issue
  reports into a ranked backlog of nexus self-fixes.
- `monitor/README.md` — runtime architecture, watcher liveness,
  env-var precedence; the canonical reference when investigating a
  watcher-side bug.
- `monitor/BOT_ADMIN_GUIDE.md` — fresh-fork stand-up walkthrough;
  step 14 is the topic-tag step that makes a new fork discoverable.
