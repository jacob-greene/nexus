---
description: "The Setty Lab software-tool ecosystem and the bug-routing protocol for lab agents. When an agent hits a bug or rough edge in a lab-authored tool (kompot, Mellon, Palantir, …), route the report FAST to the tool's code owner — open an issue on the owner's nexus asset repo (fall back to the tool's own repo) and @-ping the owner — rather than silently working around it. Carries the tool → owner → routing table and the first-line-tester rationale."
---

# nexus.tool-ecosystem — lab tools, their owners, and where to file a bug

TRIGGER when: a lab agent hits a bug, crash, wrong result, or
rough edge in a Setty Lab-authored **software tool** (a package
or method — kompot, Mellon, Crowding, Palantir, SEACells, …), and
is deciding whether to work around it silently or report it; an
agent asks "who owns tool X" or "where do I file a bug against
tool X"; the operator wants the tool→owner map maintained.

Not for third-party tools the lab merely *uses* (scanpy, anndata,
signac, ArchR) — those get filed upstream in the normal way. This
skill is specifically for tools the lab **authors and maintains**,
where a fast internal route to the owner exists.

## Why this exists — the first-line-tester contract

Each lab member runs a **nexus**: an agent workspace paired with a
GitHub "asset + issue" repo (e.g. `jacob-greene/jacob-greene-nexus-assets` is
jacob-greene's, `settylab/<other-nexus>` is otheruser's). Agents in these
nexuses do real single-cell analysis every day, and that work
leans on the lab's own software — kompot for differential
abundance, Mellon for density inference, Palantir for trajectories,
and so on.

That makes lab agents the **first-line testers** of the lab's
software. An agent running a real workload exercises these tools on
real data, at real scale, before most human users of the current
release do. When such an agent trips over a bug — a crash, a wrong
number, a missing parameter, a confusing error — that signal is
*valuable*, and it is perishable: worked around silently, it never
reaches the person who could fix it, and the next agent trips over
the same thing.

**So: do not silently work around a lab-tool bug. Route it.** A
30-second issue on the owner's tracker, with a copy-pasteable repro,
is worth more to the lab than a clever local monkey-patch that dies
with your session.

## The routing protocol

When you hit a bug or rough edge in a lab-authored tool:

1. **Identify the tool's code owner** from the table below (or, if
   the tool is not listed, from its dominant commit author —
   `GH_TOKEN=$(./monitor/mint-token.sh) gh api
   repos/settylab/<tool>/commits --jq '.[].author.login'` — then
   map to a verified lab handle).

2. **Open an issue on the owner's nexus asset repo** — that is the
   owner's control surface; their watcher will surface it. Post as
   the bot (`monitor/ng` for the nexus repo, or
   `GH_TOKEN=$(./monitor/mint-token.sh) gh issue create --repo
   settylab/<owner>-nexus …` cross-repo), then assert the author
   with `monitor/assert-bot-author.sh <url>`.

   **Fallbacks, in order**, if the owner has no nexus asset repo:
   - File on the **tool's own repo** (`settylab/<tool>/issues`),
     and `@`-ping the owner in the body.
   - If neither fits, `@`-ping the owner on the most relevant
     existing thread.

3. **Always `@`-ping the code owner's handle** in the issue body,
   whichever venue you chose — the ping is what wakes them
   (GitHub mutes self-notifications, so the bot pinging *them* is
   exactly right).

4. **Give a real repro.** Exact command, expected vs. observed as
   literal bytes, tool version / commit SHA, and the smallest input
   that triggers it. A vague "kompot seems off" wastes the owner's
   triage budget; a copy-pasteable repro gets fixed.

### Worked example

> An agent computing density with **Mellon** hits a
> `ValueError` on a 1.2M-cell AnnData that works fine at 100k cells.
> Mellon's owner is **@jacob-greene**, whose nexus asset repo is
> `jacob-greene/jacob-greene-nexus-assets`. The agent (as the bot) opens an issue on
> `jacob-greene/jacob-greene-nexus-assets` titled "Mellon: ValueError at >1M cells in
> `DensityEstimator.fit`", pastes the exact call, the full
> traceback, `mellon.__version__`, and a note that 100k cells
> succeed — then `@jacob-greene` in the body. Done in under a minute; the
> owner wakes on the ping.

### Cross-group nuance — `dpeerlab/Palantir` and other external upstreams

Several lab-authored methods live under **another group's** GitHub
org because that is their canonical home — most notably
**`dpeerlab/Palantir`** (otheruser wrote Palantir in Dana Pe'er's
lab; it still lives there and otheruser, now the lab PI, co-maintains it
alongside jacob-greene). `dpeerlab`, `broadinstitute`, and the like are
**external-public** repos under the workspace tier rules.

For a bug in an external-upstream lab tool:
- Prefer routing to the owner's **settylab-side** surface first —
  their nexus asset repo (`@otheruser` → `settylab/<other-nexus>`) —
  where you can post freely as the bot.
- **Do NOT auto-post an issue or PR to the external upstream**
  (`dpeerlab/*`, etc.). Those are external-public: **draft the
  report and STOP for operator review** before anything lands
  upstream, and grep the draft for internal identifiers (study
  names, sample IDs, cell counts, internal-repo refs) and redact.
  See the "GitHub writes — WHETHER, by repo tier" section of the
  workspace `CLAUDE.md` and `skills/nexus.bot/SKILL.md`.

## Tool → owner → routing table

**Handles are real people — verified against the current lab-member
roster.** Owners marked `handle?` could not be confidently mapped to
a current member (the dominant committer is not in the provided
roster, or the repo is co-owned); route those through the fallback
maintainer or the tool's own repo and let the operator confirm,
rather than `@`-pinging a stranger. "Not in the roster" is not proof
of departure — the committer may simply be absent from the roster we
were handed; the operator confirms current ownership.

Owners are the tool's **dominant commit author**, mapped to a
verified roster handle — **except** where operator knowledge
overrides (a tool named for / conceived by a member who had someone
else commit for them; e.g. `otheruser_annotation` is otheruser's tool
even though `@jacob-greene` authored the commits). Commit-author is the
signal; the owner-review pings are how the exceptions get corrected.
Almost every member now runs a nexus — route a bug to the owner's
nexus asset repo below.

**Member → nexus asset repo (routing target):** `@jacob-greene` →
`jacob-greene/jacob-greene-nexus-assets` · `@otheruser` → `settylab/<other-nexus>` ·
`@otheruser` → `settylab/<other-nexus>` · `@otheruser` →
`settylab/<other-nexus>` · `@otheruser` → `settylab/<other-nexus>` ·
`@<other-nexus>` → `settylab/<other-nexus>` · `@otheruser` →
`settylab/<other-nexus>` · `@otheruser` →
`settylab/<other-nexus>` · `@otheruser` →
`settylab/<other-nexus>`.

### Actively-maintained settylab packages & methods

| Tool | Purpose | Repo | Owner (handle) | File a bug at |
|---|---|---|---|---|
| **kompot** | Differential abundance & gene expression in single-cell data | `settylab/kompot` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **Mellon** | Non-parametric density inference for single-cell analysis | `settylab/Mellon` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **Crowding** | kNN-distance non-parametric density estimator | `settylab/Crowding` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **2for1separator** | Deconvolve CUT&Tag 2for1 data (`sep241`) | `settylab/2for1separator` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **kdpeak** | KDE-based ATAC peak caller | `settylab/kdpeak` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **spatial-smooth** | Composable spatial & cell-state smoothing of gene signatures | `settylab/spatial-smooth` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **convert2anndata** | R package: SingleCellExperiment / Seurat → AnnData | `settylab/convert2anndata` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **annzarro** | Zarr-based AnnData visualization tool | `settylab/annzarro` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **barnacle** | Persistent shared-node HPC workspaces via self-extending SLURM chains | `settylab/shared-node-tool` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **labsh** | Project-local JupyterLab management CLI for humans & agents | `katosh/labsh` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **agent_sandbox** | Sandbox AI agents on HPC / SLURM (the lab's agent sandbox) | `katosh/agent_sandbox` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **iso_de** | Differential of log-isoform fractions | `settylab/iso_de` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **genextf** | Associate transcription factors to genes via accessible sites | `settylab/genextf` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **jupyter_kernel_inspector** | Inspect & list Jupyter kernels | `settylab/jupyter_kernel_inspector` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **unprintable** | Find & remove hidden characters in text files | `settylab/unprintable` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **fh-hpc-skills** | Claude Code skills for Fred Hutch HPC usage | `settylab/hpc-skills` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **agent_container** | Responsible-usage tooling for AI coding agents | `settylab/agent_container` | operator (`@jacob-greene`) | `jacob-greene/jacob-greene-nexus-assets` |
| **otheruser_annotation** | Utilities to ease cell-type annotation | `settylab/otheruser_annotation` | **otheruser (`@<other-nexus>`)** — operator-confirmed owner (`@jacob-greene` committed on her behalf) | `settylab/<other-nexus>` |
| **scEcho** (a.k.a. "echo") | Statistical framework for desynchronized cell states + driver genes/REs from paired scRNA + scATAC | `settylab/scEcho` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **Desync** | Desynchronization method (`scEcho` family) | `settylab/Desync` | otheruser (`@otheruser`) — *confirm: standalone tool vs. `scEcho` component* | `settylab/<other-nexus>` |
| **Singlecept** | Quantify receptor downstream activity at single-cell resolution (scMultiome) | `settylab/Singlecept` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **ContextNet** | Infer context-specific TF-target relations from RNA + ATAC multiome | `settylab/ContextNet` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **ccflowR** / **ccflow** | Cell-cell communication flow analysis | `settylab/ccflowR`, `settylab/ccflow` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `settylab/<other-nexus>` |
| **context_specific_grn** | Context-specific GRN construction from paired RNA + ATAC | `settylab/context_specific_grn` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `settylab/<other-nexus>` |
| **trendsetter** | Plotting & utilities for single-cell trend analysis | `settylab/trendsetter` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **insilico-chip** | In-silico ChIP-seq in Python | `settylab/insilico-chip` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **atac_metacell_utilities** | Snakemake pipeline for scATAC metacell scores, chromVAR, in-silico ChIP | `settylab/atac_metacell_utilities` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **useful-plots** | Reusable plotting functions that don't fit a package | `settylab/useful-plots` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **multimodal-integration** | Multimodal single-cell integration | `settylab/multimodal-integration` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `settylab/<other-nexus>` |
| **proseg-workflow** | Proseg (spatial cell segmentation) Nextflow pipeline for Cirro | `settylab/proseg-workflow` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **check-strand** | Infer strandedness of RNA-Seq data | `otheruser/check-strand` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **TBmisc** | R package of utilities for biomedical data | `otheruser/TBmisc` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **getspan** | Gene-trend regression & span identification | `settylab/getspan` | otheruser (`handle?` — not in provided roster; recently GitHub-active, confirm owner) | `settylab/getspan` (operator to route) |
| **CellDensities** | Single-cell density utilities | `settylab/CellDensities` | `otheruser` (`handle?` — not in provided roster; fallback maintainer `@jacob-greene`) | `settylab/CellDensities` |

### Cross-group / legacy setty methods

Trajectory / metacell classics whose **canonical home is an external
group** (`dpeerlab`, Pe'er lab) — these are **external-public**:
never auto-post upstream; **draft + STOP for operator review** and
redact internal identifiers first. Route the settylab-side report to
`@otheruser`'s nexus (`settylab/<other-nexus>`) as an interim.

| Tool | Purpose | Canonical repo | Owner (handle) | File a bug at |
|---|---|---|---|---|
| **Palantir** | Single-cell trajectory detection | `dpeerlab/Palantir` | otheruser (`@otheruser`, author) + operator (`@jacob-greene`, active maintainer) | `settylab/<other-nexus>`; external upstream → **draft + operator review** |
| **Harmony** | Framework connecting scRNA-seq across discrete time points | `dpeerlab/Harmony` | otheruser (`@otheruser`) | `settylab/<other-nexus>`; upstream → **draft + review** |
| **wishbone** | Align cells along branching developmental trajectories | `dpeerlab/wishbone` | otheruser (`@otheruser`) | `settylab/<other-nexus>`; upstream → **draft + review** |
| **SEACells** | Infer metacell states from single-cell genomics | `dpeerlab/SEACells` | otheruser (`@otheruser`) + upstream Pe'er-lab maintainers | `settylab/<other-nexus>`; upstream → **draft + review** |
| **ChIPKernels** | R package: string kernels for DNA-sequence analysis | `otheruser/ChIPKernels` | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **SeqGL** | Group-lasso extraction of TF sequence signals from ChIP/DNase/ATAC | `otheruser/SeqGL` (mirror `settylab/SeqGL`) | otheruser (`@otheruser`) | `settylab/<other-nexus>` |
| **sc-dynamics-bench** | Benchmarking suite for non-splicing single-cell dynamics inference | `settylab/sc-dynamics-bench` | otheruser (`@otheruser`) — *confirm* | `settylab/<other-nexus>` |

> **Not lab-authored — file upstream normally:** `wot`
> (Waddington-OT, Broad Institute), and third-party dependencies the
> lab forks but does not maintain (`scanpy`, `anndata`, `signac`,
> `ArchR`). A bug in these is a normal upstream report, not a
> lab-routing case.
>
> **Ambiguous / low-signal repos not tabled** (a member should claim
> or disclaim them): `spatial-trajectory`, `spatial-visualization`
> (`@otheruser`, 1 commit each — likely scratch); `dolimap`,
> `knmap` (`@jacob-greene` knowledge-base engines, not single-cell tools).

## Maintaining this table

The roster and ownership drift. Re-derive an owner from the
dominant commit author when in doubt
(`gh api repos/settylab/<tool>/commits --jq '.[].author.login'`),
and only `@`-ping a handle you have verified against the current
lab-member roster (or that `gh api users/<handle>` resolves AND you
have confirmed is a current member). When a mapping is uncertain,
flag it `handle?` and route through a fallback rather than guessing
a ping. New tools get a row; retired ones get struck.

## See also

- `skills/nexus.bot/SKILL.md` — bot-identity discipline for every
  GitHub write (the issue you file goes out as the bot).
- `skills/nexus.self-fix/SKILL.md` — the analogous protocol for
  bugs in the **nexus itself** (watcher, monitor, skills); routes
  to `jacob-greene/nexus`, not to a tool owner.
- Workspace `CLAUDE.md`, "GitHub writes — identity and
  authorization" — the repo-tier rules that govern whether an
  external-upstream write may auto-post.
