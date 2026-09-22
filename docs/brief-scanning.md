# Brief scanning

Brief scans repository contents and stores a compact toolchain summary in `projects.brief`. `RepositoryScanWorker` uses the `swhid` queue and creates one temporary checkout for all due repository analyses. Brief reads that local checkout, which also supplies SWHID calculation and metadata provenance. SWH API requests use the separate `swh_api` queue.

The rake task accepts selection options through environment variables:

```bash
LIMIT=100 COHORT=all bundle exec rake projects:fetch_brief
```

Eligible projects are visible, have repository metadata, and have no stored Brief dependency result. They must have a science score above zero or publish a package used directly by a scientific project. `COHORT` accepts `all`, `joss`, or `non_joss`. `LIMIT` defaults to 50 for the rake task.

`SHARD_COUNT` and `SHARD` select a stable subset by project ID. For example, these commands enqueue the JOSS comparison group and roughly one thirty-second of eligible non-JOSS projects:

```bash
LIMIT=4000 COHORT=joss bundle exec rake projects:fetch_brief
LIMIT=4000 COHORT=non_joss SHARD_COUNT=32 SHARD=0 bundle exec rake projects:fetch_brief
```

The rake task only enqueues jobs. The application worker process must be running before the queue will drain. Successful scans store selected Brief fields, including `manifests` and `dependencies`. An empty `dependencies` array records that the scan found none. Successful results saved before dependency storage was added have no dependency key and receive one new scan.

Clone, timeout, and parse failures store an error and attempt time in `projects.brief`, which keeps repeated cohort runs from retrying the same failed repository. Queue uniqueness prevents duplicate waiting scans, and a per-project database lock prevents overlapping scans. Workers recheck saved results before cloning. Each analysis saves its own results; a Brief command failure still permits SWHID calculation. The checkout is removed after processing, including on failure.

Brief results update the Science Score. If a project becomes scientifically eligible after Brief runs, SWHIDs are calculated from the same checkout. Direct dependencies from Brief are used by the dependency indexer when stored repos manifest data has no usable direct dependencies. `ProjectRepositoryScanner` owns the checkout and coordinates the analyses; additional repository analysis can use that path without another clone.
