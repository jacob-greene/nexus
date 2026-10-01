# Literature research (`ng lit`)

`ng lit` is the nexus literature-research tool: on-demand, content-relevance
paper discovery for Claude workers, deduplicated against a local reference
library, with a one-step "pull this paper into the library" verb. It is a
native reimplementation (plain `curl` + `jq`) of the small subset of
[bipartite](https://github.com/matsen/bipartite) (`bip`) utilities the nexus
needs, so it ships in nexus-code and works in any operator's clone with **no
dependency on a locally-installed `bip` binary**.

Literature research is a first-class part of scientific work in the nexus.
Workers on a scientific task should use `ng lit` to ground claims in the
literature whenever relevant, and may cite the references they find (and the
statements those references support) in their reports — see
[the `nexus.lit` skill](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md).

## Backends

| Backend | What it is | Key |
|---|---|---|
| **PubMed** | NCBI E-utilities over MEDLINE/PubMed; biomedical and life-science literature | **none needed**; optional free key raises the rate limit |
| **Semantic Scholar (S2)** | Allen Institute academic graph; relevance search, citation graph, metadata | free, instant |
| **ASTA** | Allen AI academic search tool (MCP) | request via the ASTA program |

**PubMed works out of the box.** It needs no key, so a fresh nexus can
search the literature before anyone configures anything. When no S2 or ASTA
key is configured, PubMed is the default backend.

The S2 and ASTA keys are **optional**. A keyed backend with no key is
**skipped with a note** — never a silent hang, never a hard failure of the
whole command. An API error (bad key, rate limit, malformed response) is
reported on stderr with a non-zero exit. It is never returned as an empty
result list.

### Choosing a backend

`--source` selects the backend(s):

| `--source` | Queries |
|---|---|
| (omitted) | the configured keyed backends (S2 and/or ASTA); PubMed when neither is configured |
| `pubmed` | PubMed only |
| `s2` | Semantic Scholar only |
| `asta` | ASTA only |
| `both` | S2 + ASTA (the pre-PubMed default, kept for compatibility) |
| `all` | PubMed + S2 + ASTA |

PubMed indexes biomedical and life-science journals. For computer science,
statistics or physics papers outside PubMed, use S2. PubMed's query syntax
applies to `--source pubmed`: field tags such as `[tiab]` (title/abstract)
and `[au]` (author), and `AND`/`OR`/`NOT`, work in the query string. Results
come back in PubMed's relevance order.

## Acquiring keys

### PubMed (optional)

PubMed needs no key. Two optional settings improve how the nexus uses it:

| Setting | Env var | Config key | Effect |
|---|---|---|---|
| API key | `NCBI_API_KEY` | `lit.ncbi_api_key` | raises the NCBI limit from 3 to 10 requests/s |
| Contact email | `NCBI_EMAIL` | `lit.ncbi_email` | sent as `email=`; NCBI asks callers for a contact so it can reach you before it blocks heavy traffic |
| Tool name | `NCBI_TOOL` | `lit.ncbi_tool` | sent as `tool=`; default `nexus-lit` |

To get an NCBI API key:

1. Sign in to (or create) an NCBI account at <https://account.ncbi.nlm.nih.gov/>.
2. Open **Account settings** (<https://account.ncbi.nlm.nih.gov/settings/>).
3. Under **API Key Management**, select **Create an API Key** and copy it.

`ng lit` paces its own requests under the applicable limit and retries on
HTTP 429. The NCBI limit applies per IP address, so pacing also holds across
concurrent `ng lit` runs of the same user (a lock file under `$TMPDIR`).

### Semantic Scholar (S2)

1. Visit <https://www.semanticscholar.org/product/api#api-key-form>.
2. Fill in the request form (name, email, intended use). Keys are issued
   quickly, often within a day, sometimes instantly.
3. You will receive the key by email.

### ASTA (Allen AI)

ASTA keys are issued through the ASTA program at Allen AI (the
`asta-tools.allen.ai` MCP service). Request access through the ASTA program
contact; the key is delivered as a string you install exactly like the S2 key.

## Installing a key

Resolution order per backend (first hit wins):

1. **Environment** — `export S2_API_KEY=...` (or `ASTA_API_KEY=...`,
   `NCBI_API_KEY=...`). Wins over all config; best for ephemeral or CI use.
2. **Nexus config** — add under a `lit:` block in `config/nexus.yml` (which is
   gitignored, so inlining the secret is safe):

   ```yaml
   lit:
     s2_api_key: "your-s2-key"
     asta_api_key: "your-asta-key"   # optional
     ncbi_api_key: "your-ncbi-key"   # optional; PubMed works without it
     ncbi_email: "you@example.org"   # optional; recommended by NCBI
   ```

3. **Legacy `bip` config** (S2 and ASTA only) — `s2_api_key:` / `asta_api_key:` in
   `<nexus.root>/.config/bip/config.yml`. Read as a fallback so an existing
   `bip` setup keeps working without migration.

Verify with `ng lit status`.

## The reference library

A JSONL file (one paper per line) that `ng lit search` dedups against and
`ng lit add` appends to.

- **Default path:** `<nexus.root>/.bipartite/refs.jsonl`.
- **Versioned library:** set `lit.library_path` in `config/nexus.yml` to a path
  inside your asset repo to track the library under version control.

Record schema (compatible with `bip`'s `refs.jsonl`): `id`, `doi`, `title`,
`authors[]` (`{first,last}`), `abstract`, `venue`, `published.{year,month,day}`,
`source.{type,id}`, `pmid`, `pmcid`. Records added through PubMed carry
`source.type: "pubmed"`, the PMID, the PMCID when there is one, and the
abstract.

## Commands

```
ng lit status [--human]
ng lit search "<query>" [--source pubmed|s2|asta|both|all] [--limit N] [--year A:B] [--human]
ng lit add <DOI|PMID|S2-id> [--human]
ng lit setup
```

Default output is JSON (for agent consumption); `--human` is readable.

### `ng lit status`

Reports the library path + count, which backends are configured (and from
which source — env / config / legacy-bip, never the key itself), the PubMed
rate limit (`3/s` or `10/s`), whether an NCBI contact email is set, and the
default `--source`. It exits 0: PubMed is always available.

### `ng lit search`

Content-relevance discovery across the selected backend(s) (see
[Choosing a backend](#choosing-a-backend)). Results are deduplicated across
backends by DOI and PMID, keeping each backend's relevance order. Each is
annotated with `in_library` (true if its DOI or PMID is already in the
reference library). A requested keyed backend with no key is skipped with a
note. `--year A:B` filters by publication year on S2 and PubMed.

Every result has the same fields whatever its backend: `source`, `id`,
`pmid`, `title`, `authors`, `year`, `venue` (the journal, for PubMed), `doi`,
`citations` (null for PubMed), `url`, `in_library`.

PubMed drops a query term it cannot match and still returns hits for the
rest, so a typo silently broadens the query. `ng lit` reports each dropped or
ignored term as a stderr note, and in the JSON output as `warnings` (a list,
empty when clean) and `pubmed_query_translation` (the query PubMed actually
ran). Check `warnings` before you trust a result set.

```console
$ ng lit search "GENCODE reference annotation" --source pubmed --limit 1 --human
Found 1 papers (sources: pubmed)

  [new] GENCODE: reference annotation for the human and mouse genomes in 2023.
      Frankish A, Carbonell-Sala S, Diekhans M, Jungreis I, Loveland JE, Mudge JM, et al.
      Nucleic acids research (2023)  cites:?  doi:10.1093/nar/gkac1071  pmid:36420896  [pubmed]

$ ng lit search "single-cell differential abundance testing" --limit 5 --human
Found 5 papers (sources: s2)

  [IN-LIB] Differential abundance testing on single-cell data using K-nearest neighbour graphs
      E. Dann, N. Henderson, S. Teichmann, M. Morgan, J. Marioni
      Nature Biotechnology (2021)  cites:653  doi:10.1038/s41587-021-01033-z  [s2]
  ...
```

### `ng lit add`

Fetches a paper's metadata and appends a schema-compatible record to the
library. It accepts three identifier forms:

| Identifier | Example | Resolved through |
|---|---|---|
| PMID | `36420896` or `PMID:36420896` | PubMed (no key) |
| DOI | `10.1093/nar/gkac1071` | S2 when an S2 key is set; otherwise PubMed |
| S2 paper id | `CorpusId:123`, a 40-hex id | S2 (needs an S2 key) |

A DOI resolved through PubMed must match exactly one PubMed record. A DOI that
PubMed does not index (most non-biomedical papers) needs an S2 key. The
record is dedup-checked by DOI and PMID and refused if already present.

### `ng lit setup`

Prints the key-acquisition and installation references (the same guidance shown
when the tool is unconfigured).

## Optional: in-library semantic similarity

Content discovery (S2/ASTA relevance search) needs **no** embeddings. A separate
embedding-based "find papers in my library similar to X" capability exists in
`bip` (`bip semantic`/`bip index build`) and requires a running Ollama with the
`all-minilm:l6-v2` model; it is **not** required for discovery or library
updates and is not reimplemented here.

## See also

- [`nexus.lit` skill](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md) — when and how a worker
  should reach for literature research.
- [`ng` CLI reference](ng-cli.md) — the full verb index.
