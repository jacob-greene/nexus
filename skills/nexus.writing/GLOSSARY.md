# Nexus glossary — approved definitions

One approved definition per internal term. Copy the definition
verbatim when you first use the term in an artefact. Do not write
a local variant.

This file exists because rule 6 of `nexus.writing` asks for
definitions that stay consistent across turns. An agent cannot
remember what the last session wrote. A tracked file can.

## How to use it

| Situation | Action |
|---|---|
| You use a listed term | Copy its definition into your first-use sentence. |
| Your term is missing | Add a row in the same PR that first uses the term. |
| A definition reads wrong | Fix it here. Do not work around it locally. |

Definitions are one clause. They must fit inside a sentence
after an em dash or inside parentheses. Keep them under 20 words.

## Nexus terms

| Term | Approved definition |
|---|---|
| nexus | a coordination repo that hosts project checkouts and turns GitHub issues into a control surface |
| orchestrator | the long-running agent that reads the watcher and dispatches work to workers |
| watcher | the headless poller that snapshots GitHub and the workspace, then prints findings for the orchestrator |
| worker | an agent spawned into its own tmux window to do one delegated task |
| emit | one block the watcher prints for the orchestrator to act on |
| eligible comment | a GitHub comment the watcher judges as new work for the orchestrator |
| floor | the `## Worker floor` section injected verbatim into every worker spawn prompt |
| spawn | to launch a worker in a new tmux window via `monitor/spawn-worker.sh` |
| wrap-up | the hand-off step that checks a report, uploads it, and comments the link on the issue |
| report | the file under `reports/` an agent writes before finishing, so the work can resume without the session |
| skeptic | an independent agent that adversarially rechecks another worker's result |
| parked | idle on purpose and exempt from window cleanup, usually while waiting for a skeptic |
| ghost | Claude Code's dim autosuggest text in a pane, which looks like typed input but is not |
| preflight | a check that runs before an action and blocks it when a condition fails |
| unstick | the watcher's routine that clears a blocked agent pane, by answering a dialog or re-submitting |
| rocket | the reaction added to a comment to mark it fully processed, by the bot or by the operator |
| dashboard | the structured body of the overview issue that reports current nexus state |
| overview issue | the routing-only issue tagged `nexus:overview`, normally issue 1 |
| secondary clone | a clone or worktree a worker edits freely, landing canonical changes by PR or via the primary clone |
| bot | the GitHub App identity that makes every write, so the operator gets notified |

## Project terms

Add domain terms here when they recur across reports. A term used
once in one report does not belong in this file; define it inline
and move on.

| Term | Approved definition |
|---|---|
| _(none yet)_ | |
