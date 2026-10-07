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
   that would be published (`lib`, `mix.exs`, `README.md`, `RELEASING.md`,
   `LICENSE`, `.formatter.exs`) with `licenses: ["MIT"]`, and `mix docs`
   builds the documentation.

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
