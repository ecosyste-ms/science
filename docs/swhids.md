# SWHIDs

Project sync queues `FetchSwhidWorker` after updating Science Score. Eligible projects are visible, have repository metadata, meet the scientific threshold of 20, and have no stored SWHID result. The worker rechecks eligibility before scanning and uses the `swhid` Sidekiq queue with weight 1, alongside `brief` at weight 1 and `default` at weight 5.

The worker clones the current default branch and stores its revision and checkout-directory identifiers in `projects.swhids`. Each command has a 120-second timeout, and the temporary checkout is removed after the scan. The Docker image installs the `swhid-go` v0.1.0 CLI as `swhid`; local workers also need that executable on `PATH`.

The stored result includes the clone origin, commit, attempt time, total duration, and separate `revision` and `directory` results. Each calculation records its SWHID, binary version, argument array, input identity, method, duration, and status. Errors are limited to 500 characters. As with Brief, stored successes and calculation errors prevent automatic rescanning; clear `swhids` to request another attempt. Unexpected job errors have three Sidekiq retries. SWHID results do not affect Science Score. Tags and releases are not scanned.

Inspect a saved result in the Rails console:

```ruby
project = Project.find(476); pp project.swhids; nil
```

Queue one eligible project from a Rails console:

```ruby
project = Project.find(476); puts "job_id: #{project.fetch_swhids_async.inspect}"; nil
```

Local archive experiments can call the calculator from a Rails console without changing project records:

```ruby
pp SwhidCalculator.new.calculate(type: "directory", path: "/tmp/extracted/source", artifact: "/tmp/source.tar.gz"); nil
```

`artifact` records the archive's SHA-256 beside the extracted-directory SWHID. The caller supplies the extracted path; the calculator does not download, extract, or normalize archives, or verify that the directory came from that artifact. Record extraction choices alongside the output when comparing archives.

Directory calculation hashes the checkout or extracted filesystem using the CLI's handling of Git index modes and symlinks. Checkout filters can change file contents relative to Git's stored tree. These identifiers do not establish Software Heritage archive coverage.
