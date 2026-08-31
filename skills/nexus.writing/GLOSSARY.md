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
| resume | to relaunch a worker into its own window, so it continues the same task |
| lifecycle anchor | the `spawn` action-log event that marks when a window's current life began |
| wrap-up | the hand-off step that checks a report, uploads it, and comments the link on the issue |
| re-wrap-up | a second wrap-up that the same worker runs on the same result |
| report | the file under `reports/` an agent writes before finishing, so the work can resume without the session |
| skeptic | an independent agent that adversarially rechecks another worker's result |
| skeptic round | one validation pass, from the request that opens it to the verdict that closes it |
| verdict | the skeptic's ruling on a worker's result, which closes the skeptic round |
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
| arrow | one ArchR HDF5 file holding the fragments of a single sequencing library |
| arrow row | one cell as named inside one arrow, before any cross-arrow merge |
| canonical cell | one physical cell, named identically across every arrow and assay that measured it |
| pooling | summing the arrow rows that name one canonical cell into a single matrix column |
| pooling guard | the check that a pooled column equals the sum of its arrow columns, feature by feature |
| Bivalent | the co-CUT&Tag assay of reads carrying both an H3K27me3 and an H3K4 antibody |
| minFrags | the createArrowFiles argument setting the fewest fragments a cell needs to be kept |
| pc23 basis | the top 23 principal directions of the mean-centred GLUE embedding, holding 99% of its variance |
| native label | the cell-type label a cell already carries in its own assay, before any joint re-clustering |
| promoter layer | the per-cell count matrix of fragments falling in each gene's promoter window |
| pseudobulk | the summed counts of a cell group, expressed as log-CPM, used as one profile per group |
| log-CPM | log1p of counts per million, computed after summing a group rather than per cell |
| signature z-score | the mean z-score of a curated marker set, taken across the groups being compared |
| reference correlation | the Pearson correlation between a group's pseudobulk and the pseudobulk of cells already carrying a label |
| margin | the gap between the best-matching label's reference correlation and the runner-up's |
| cell bootstrap | resampling the cells of one group with replacement, then recomputing the group's statistic |
| lift over chance | (observed rate minus chance rate) divided by (1 minus chance rate) |
| binomial thinning | drawing a smaller count from each observed count, so every group reaches one common read depth |
| per-label recall | the fraction of one label's cells that keep that label under an alternative clustering |
| plurality | the single most common native label among the labelled cells of one vocabulary in a cluster |
| purity | the plurality label's share of the labelled cells of that vocabulary in that cluster |
| override | a cluster whose assigned label differs from its plurality, on marker evidence |
| z ceiling | the largest value an across-group z-score can take, (n minus 1) divided by root n |
| block | a base label that the issue-55 sub-clustering split into finer progenitor labels |
| label transfer | reading a per-cell label out of a frozen file and applying it to a different clustering of the same cells |
| terminal | a cell-type label used as an endpoint anchor by downstream pseudotime work |
| mutation test | injecting into an input the exact defect a guard was written to catch, then checking that the guard fails |
| dead guard | an assert whose condition is forced true by the lines that build its operands, so no input can make it fail |
| peak | one interval of a called accessibility peak set; in this project the source set is a fixed-width 500 bp interval set, held in the project's ATAC features file |
| extended peak | a peak grown by a fixed distance on each side and NOT merged with its neighbours, so two extended intervals can both count the same fragment |
| promoter peak | a peak whose CENTRE falls inside a promoter window, the `ArchR:::.fastAnnoPeaks` rule; the window is the gene start, 2,000 bp upstream to 100 bp downstream |
| me3-down gene | a gene that loses the K27me3 mark along one lineage, by the edgeR test defined in the me2/me3 onset-lag notebook |
| onset | the pseudotime at which a feature's z-scored trend along pseudotime is highest |
| censored onset | an onset that lands on the first or last pseudotime grid point, so the trend never turned inside the observed range |
| support | the number of cells with a non-zero raw count for one feature, inside one lineage |
| interior onset | an onset that is not censored, so the trend turned inside the observed pseudotime range |
| marginal median | a per-panel median taken over the rows that are interior IN THAT PANEL, so each panel is summarised over its own row subset and the panels are not directly comparable |
| paired lag | the median, over rows interior in BOTH panels of a pair, of the per-row onset difference between them; the same rows enter both terms, so a panel-dependent selection cancels |
