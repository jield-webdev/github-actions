# Jield shared GitHub workflows

Reusable GitHub Actions workflows for projects in `jield-webdev`.

Each consuming repository keeps a small caller workflow containing its event
filters, concurrency policy, permissions, and project configuration. This
repository owns the implementation.

## Writerside documentation and GitHub Pages

[`writerside-pages.yml`](.github/workflows/writerside-pages.yml) builds and checks
Writerside documentation, maintains a versioned site in a content-store branch,
and deploys that site using GitHub Pages.

Copy [`examples/documentation.yml`](examples/documentation.yml) into the consuming
repository's `.github/workflows/` directory and set its instance, Docker image
version, and public site URL. The job calling the workflow looks like this:

```yaml
jobs:
  documentation:
    uses: jield-webdev/github-actions/.github/workflows/writerside-pages.yml@v1
    permissions:
      contents: write
      pages: write
      id-token: write
    with:
      instance: Writerside/ipm
      docker-version: "2026.10.0423"
      site-url: https://example.github.io/project
      # custom-domain: docs.example.com
      release-ref: ${{ inputs.release_ref || '' }}
```

### Inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `instance` | Yes | — | Writerside directory and instance ID, such as `Writerside/ipm` or `docs/guide` |
| `docker-version` | Yes | — | Writerside builder Docker image version |
| `site-url` | Yes | — | Public site URL, including a project base path when applicable |
| `custom-domain` | No | Empty | Write this domain to `CNAME`; when empty, preserve an existing `CNAME` |
| `release-ref` | No | Empty | Tag to add or rebuild during a manual `workflow_dispatch` run |
| `current-branch` | No | `main` | Branch used for the site root |
| `develop-branch` | No | `develop` | Branch published under `/develop/` |
| `content-branch` | No | `gh-pages` | Persistent site and historical-release storage |
| `environment` | No | `github-pages` | GitHub environment used for deployment |

The Writerside directory must contain `writerside.cfg` and
`cfg/buildprofiles.xml`. The workflow derives the directory and build archive name
from `instance`. Both configured source branches must exist in the caller's
repository.

Set `site-url` to the URL visitors actually use. For a custom domain, use that
domain in `site-url` as well as `custom-domain`. For a project site, include the
repository base path; the version switcher retains it.

### Publication behavior

| Trigger in the caller | Result |
| --- | --- |
| Pull request | Build and check the PR commit; no publication |
| Push to the current or development branch | Refresh the site root and `/develop/`; preserve archived releases |
| Push to `release/X.Y` or `release/X.Y.Z` | Also publish a preview under `/releases/<version>/` |
| Push of a `vX.Y.Z` tag | Publish that commit at the site root and archive it under `/releases/X.Y.Z/` |
| Manual run with `release_ref` | Add or rebuild that release while building the configured current branch for the site root |
| Manual run without `release_ref` | Follow the selected ref's normal behavior; other branches are checked without publication |

Prerelease suffixes such as `v1.2.3-rc.1` are supported. Previews never overwrite
an already published release with the same version. Development and preview
content is marked `noindex`. A manual release rebuild refreshes current docs from
the configured current branch; it does not promote the requested old release to
the site root.

### Repository setup

1. In the consuming repository, choose **Settings → Pages → Build and deployment →
   Source → GitHub Actions**.
2. Ensure its Actions policy permits this reusable workflow and the upstream
   Writerside and GitHub actions it uses.
3. Give the calling job the three permissions shown above. Preparation and build
   jobs reduce their permissions to `contents: read`; only deployment needs writes.
4. Configure the deployment environment, including any approval or branch/tag
   policies, in the consuming repository.
5. Keep the publishing concurrency group shared across branches, as in the example.
   Publishing updates one content store and one Pages site.

`actions/checkout` inside a reusable workflow checks out the caller's repository.
Published files, the content-store branch, the Pages deployment, and the
`GITHUB_TOKEN` therefore all belong to the consuming repository. No personal
access token or inherited secrets are required.

The shared repository is public, so callers do not need private-workflow access
configuration. See GitHub's [reusable workflow reference](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).

## Adding workflows

Add each reusable workflow directly under `.github/workflows/` and give it an
`on: workflow_call` interface with typed inputs. Add a caller example under
`examples/`, document required permissions and behavior here, and extend validation
when the workflow contains custom logic. Callers check out their own source, so
scripts stored only in this repository are not automatically available to them.

## Versioning

`main` is the development branch. `v1.0.0` identifies the initial release and `v1`
is its stable major-version reference. Consumers can use `@v1` for compatible
updates, an exact release tag for a fixed release, or a full commit SHA.

Run validation before publishing a release. Tag each release with its exact
version and advance the matching major tag after validation succeeds. Keep
breaking input or behavior changes for a new major version.

## Validation

```sh
actionlint
ruby tests/writerside_pages_test.rb
```

Tests need Ruby with `minitest`, Bash, Git, jq, Perl, rsync, zip, unzip, and a
GNU-compatible `sort -V`. On macOS the tests use `gsort` if installed. Test builds
use small fixture archives and temporary local repositories; they do not run
Docker, contact GitHub, or deploy a site. CI also checks workflow syntax and shell
scripts with actionlint.
