# Research organization domains

Research organization domains connect repository owners and committer email addresses to institutions. Matches contribute to Science Score, power institutional owner pages, and select GitHub organizations for repository discovery.

## Domain sources

The active domain set combines a versioned manual file with a versioned ROR release. Each source activates its versions independently:

| Source | Location | Strength |
| --- | --- | ---: |
| Manual | `db/seeds/research_organization_domains.yml` | 1.0 |
| ROR education, government, facility, nonprofit, healthcare, or archive record | ROR data release published through Zenodo | 1.0 |
| Other ROR organization types, including companies | ROR data release published through Zenodo | 0.4 |

The manual YAML contains a version and a domain list. Changing the list requires a new version so the importer can insert and activate the replacement set.

The ROR importer reads Zenodo record `6347574`, downloads its ZIP archive, checks the MD5 checksum, and extracts the CSV with `bsdtar`. Only active ROR records are considered. Curated ROR domains are preferred; when a record has none, a website contributes its host only when the URL points at the host root. Public suffixes such as `gov.uk` are rejected.

At least 10,000 valid ROR domains must be present before a new ROR version can become active. New rows are inserted as inactive, then switched into service inside a transaction. A failed import deletes its incomplete version and leaves the prior active version in place.

## Matching rules

Input domains are lowercased, stripped of a leading `www.`, and stripped of a final dot. Values containing a path or `@` are rejected. Matching checks the full host and then each parent suffix on label boundaries, so `data.inbo.be` can match `inbo.be`, while `notinbo.be` cannot.

When more than one active record has the same domain, the higher strength wins. ROR wins a tie against another source. The matcher returns the matched domain, source, external ID, organization name, organization types, and strength.

Two hostname heuristics apply after stored-domain matching. Labels beginning with `univ-`, `u-`, `uni-`, `tu-`, or `fh-` match at strength 1.0. Exact labels named `university`, `college`, `institute`, or `academia` also match. Substrings such as `education` or `myuniversity` do not match those rules.

Active domains are cached in each process for one day. An empty result is cached for five minutes. Activating a domain version resets the in-process cache.

## Owner and committer use

Only organization owners are classified. The matcher extracts a domain from the owner's website and saves the matched domain in `owners.institutional_domain`. Owner creation and changes to website or kind run this classification, while the refresh task can reclassify all existing owners in batches of 500.

ROR company records remain valid institutional owner matches. `ResearchOrganizationDomainMatcher.academic_match` excludes companies when Science Score examines committer email domains, which prevents corporate addresses from contributing academic-email evidence.

Every 15 minutes, `owners:check_ror_repositories` selects up to 25 visible GitHub organizations with ROR-backed domains whose repository inventory has not been checked within one day. It imports repositories returned for those owners and records the check time. Manual and heuristic matches do not enter this scheduled owner expansion.

## Refreshing and inspecting domains

`research_organizations:sync` runs at `04:00` every Monday. It refreshes the manual source, imports the current ROR release, and reclassifies owners only when one of the active versions changed. If a changed manual version succeeds and the ROR download fails, owner reclassification still runs for the manual change before the task raises the ROR error.

```bash
bundle exec rake research_organizations:sync
bundle exec rake research_organizations:stats
```

Reclassify owners without downloading domain data. This processes existing owners in batches of 500:

```bash
bundle exec rake research_organizations:reclassify_owners
```

Inspect a single match in a Rails console. The subdomain example shows parent-suffix matching:

```ruby
domain = "data.inbo.be"; match = ResearchOrganizationDomainMatcher.match(domain); puts "domain: #{domain.inspect}"; pp match; nil
```

Inspect the current population without loading all domain rows. Both counts stay inside aggregate SQL queries:

```ruby
ResearchOrganizationDomain.active.group(:source, :source_version).count.each { |(source, version), count| puts "source=#{source.inspect} version=#{version.inspect} domains=#{count.inspect}" }; puts "institutional_owners: #{Owner.institutional.count.inspect}"; nil
```

Science Score consumes both owner and committer matches as described in [Science Score](science-score.md). On the non-JOSS path, match strengths multiply their signal weights.
