# Releasing

The package is published to [Hex](https://hex.pm/packages/docuconf) as
`docuconf`, with its docs on HexDocs, by `.github/workflows/release.yml` when
a `v*` tag is pushed.

## Before the first release

1. **Create the Hex package owner.** Register the organisation account on
   hex.pm (or use a maintainer account) that will own `docuconf`.
2. **Create an API key.** Hex has no OIDC trusted publishing, so CI needs
   a key. Create one limited to publishing:
   `mix hex.user key generate --key-name docuconf-elixir-ci --permission api:write`
   (or on hex.pm under Dashboard, Keys). Store it as the `HEX_API_KEY`
   secret of a GitHub environment named `hex`. Restrict that environment to
   `v*` tags and, if you like, require a reviewer.
3. Check the package locally: `mix hex.build` lists the files and metadata
   that would be published (`lib`, `mix.exs`, `README.md`,
   `LICENSE`, `.formatter.exs`) with `licenses: ["MIT"]`, and `mix docs`
   builds the documentation.
4. In `README.md`, replace the GitHub dependency under "1. Install" with
   `{:docuconf, "~> 0.1"}` once the package is on Hex.

## Each release

Releases are automated with
[release-please](https://github.com/googleapis/release-please); see
[CONTRIBUTING.md](CONTRIBUTING.md#how-releases-happen) for the commit
conventions it reads.

1. Merge the open release PR (`chore(main): release X.Y.Z`). It already
   updates `@version` in `mix.exs` and `CHANGELOG.md`. The golden file and
   the example contract do not need regenerating: their comparisons ignore
   `metadata.generator.version`.
2. release-please tags the merge commit `vX.Y.Z` and creates the GitHub
   release with the changelog entries.
3. The workflow checks that the tag matches `mix.exs`, runs the tests
   (including `cue vet` against the docuconf-go meta-schema), then runs
   `mix hex.publish --yes`, which publishes the package and its docs.

If the release PR was created with `GITHUB_TOKEN` (no release GitHub App
configured), the tag does not trigger `release.yml` by itself, so
`.github/workflows/release-please.yml` starts it with `gh workflow run`. To
redo a release by hand: `gh workflow run release.yml --ref vX.Y.Z`.

To retire a bad release, use `mix hex.retire docuconf 0.1.0 invalid --message "..."`
rather than reverting it. Hex allows `mix hex.publish --revert` only within
an hour of publishing.

## GitHub Packages and Releases

GitHub Packages has no Hex registry, so the GitHub copy of each release is the
GitHub Release. The `github` job in `.github/workflows/release.yml` runs on
the same `v*` tags, repeats the tag check, compile and tests, builds the Hex
package with `mix hex.build`, creates the GitHub Release for the tag if it
does not exist, and attaches `docuconf-<version>.tar`, the exact tarball Hex
would get.

It does not depend on the Hex `publish` job, so it works before the Hex
owner, API key and `hex` environment exist. It uses only the workflow's own
`GITHUB_TOKEN` (`contents: write`); there are no secrets or accounts to set
up, and nothing to configure beyond the `Docuconf` organization allowing
`GITHUB_TOKEN` write access (it does unless restricted under Organization
settings > Actions).

### Installing from a GitHub Release

No token is needed for a public repository. Mix installs from git, so the
simplest way to use a release without Hex is the tag itself:

```elixir
{:docuconf, github: "Docuconf/docuconf-elixir", tag: "v0.1.0"}
```

To use the released tarball, download and unpack it, and point Mix at the
directory:

```sh
curl -sSLO https://github.com/Docuconf/docuconf-elixir/releases/download/v0.1.0/docuconf-0.1.0.tar
mkdir -p vendor/docuconf && tar -xOf docuconf-0.1.0.tar contents.tar.gz | tar -xzf - -C vendor/docuconf
```

```elixir
{:docuconf, path: "vendor/docuconf"}
```
