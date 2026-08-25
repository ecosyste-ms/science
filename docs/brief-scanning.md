# Brief scanning

Brief scans repository contents and stores a compact toolchain summary in `projects.brief`. `FetchBriefWorker` uses the `brief` Sidekiq queue because each scan clones a repository. The shared worker process polls `default` and `brief` at relative weights of five to one.

The rake task accepts selection options through environment variables:

```bash
LIMIT=100 COHORT=all bundle exec rake projects:fetch_brief
```

Eligible projects are visible, have repository metadata, have a science score above zero, and have no stored Brief result. `COHORT` accepts `all`, `joss`, or `non_joss`. `LIMIT` defaults to 100.

`SHARD_COUNT` and `SHARD` select a stable subset by project ID. For example, these commands enqueue the JOSS comparison group and roughly one thirty-second of eligible non-JOSS projects:

```bash
LIMIT=4000 COHORT=joss bundle exec rake projects:fetch_brief
LIMIT=4000 COHORT=non_joss SHARD_COUNT=32 SHARD=0 bundle exec rake projects:fetch_brief
```

The rake task only enqueues jobs. The application worker process must be running before the queue will drain. Successful scans store selected Brief fields. Clone, timeout, and parse failures store an error and attempt time in `projects.brief`, which keeps repeated cohort runs from retrying the same failed repository. Avoid enqueueing the same cohort again while its earlier jobs remain queued. A project has no `brief` value until its job starts, so concurrent task runs can enqueue duplicate jobs.
