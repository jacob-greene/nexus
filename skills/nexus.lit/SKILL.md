---
description: "Literature research for scientific work: ng lit content-relevance discovery (PubMed, S2, ASTA) deduped against the reference library, ng lit add to grow it, and the convention that scientific reports cite the references (and supporting statements) they find. Use when a scientific task needs grounding in the literature."
---

# nexus.lit — literature research for scientific work

TRIGGER when: a worker is doing scientific work (analysis, a method
write-up, an experiment, a manuscript or a claim that should be
grounded in prior art); a worker needs to know whether a phenomenon,
method, or result is already described in the literature; a worker
wants to find the canonical reference for a claim; a worker is
deciding what to cite in a scientific report.

## The principle

Literature research is an important aspect of **any** scientific task.
Respective workers should consider it whenever relevant — not as a
separate chore but as part of grounding the work. When you make a
quantitative or mechanistic claim, ask whether the literature confirms,
contradicts, or contextualizes it, and reach for `ng lit` to check.

## The tool: `ng lit`

On-demand, content-relevance paper discovery, native to the nexus (no
`bip` install required). Default output is JSON (agent-friendly);
`--human` is readable.

```
ng lit status                                    # backends / library / readiness
ng lit search "<query>" [--source pubmed|s2|asta|both|all] [--limit N] [--year A:B]
ng lit add <DOI|PMID|S2-id>                      # pull a paper into the library
ng lit setup                                     # key-acquisition references
```

- **Discovery** — `ng lit search "<content query>"` queries PubMed,
  Semantic Scholar or ASTA by relevance and **dedups against the local
  reference library** by DOI and PMID, annotating each hit
  `in_library: true|false`. Frame the query by content (the
  phenomenon/method/claim), not by title.
- **PubMed works with no key.** It is the default backend when no
  S2/ASTA key is configured. It covers biomedical and life-science
  literature. For computer science, physics or methods papers outside
  PubMed, use `--source s2` (needs an S2 key). `--source all` queries
  every backend you have. PubMed's query syntax applies: field tags such
  as `[tiab]` and `[au]`, and `AND`/`OR`, work in the query string.
  PubMed silently drops a term it cannot match. Read the `warnings` field
  (and the stderr note) before you trust the hits.
- **Grow the library** — `ng lit add <DOI|PMID>` fetches metadata
  (with the abstract, for PubMed) and appends a record. Add the papers
  you end up relying on so the library (and future dedup) stays current.
- **Backends degrade gracefully** — a keyed backend with no key is
  skipped with a note, never a hang. An API error is reported on stderr
  with a non-zero exit, never as an empty result. See `ng lit setup` and
  [`docs/reference/literature.md`](../../docs/reference/literature.md)
  for key acquisition (all free).

## Citing in reports

Scientific reports **may include the literature references you find and
the statements those references support** — unless irrelevant to the
work. Prefer:

- A short claim → reference mapping (what the source establishes), not a
  bare URL dump.
- A real, resolvable identifier (DOI, or PMID when there is no DOI) for
  each reference.
- Inclusion only where it grounds or qualifies a claim in the report;
  omit literature that does not bear on the work.

This complements the report schema in [`nexus.report`](../nexus.report/SKILL.md):
references live in the body alongside the claims they support.

## What it is not

- Not an embedding/semantic-similarity search over your own library
  (that is `bip semantic`, which needs Ollama and is **not** required
  here). `ng lit` discovery is content-relevance search against
  PubMed/S2/ASTA.
- Not a replacement for reading the paper — it finds and catalogs;
  judgment about relevance and correctness stays with the worker.

Full reference: [`docs/reference/literature.md`](../../docs/reference/literature.md).
