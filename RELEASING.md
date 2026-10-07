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

1. Update `@version` in `mix.exs`. The SDK writes that version into every
   exported contract (`metadata.generator.version`), so regenerate the
   golden file and the example contract:
   ```sh
   UPDATE_GOLDEN=1 mix test
   (cd examples/orders && mix docuconf.export)
   ```
2. Commit, then tag and push:
   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The workflow checks that the tag matches `mix.exs`, runs the tests
   (including `cue vet` against the docuconf-go meta-schema), then runs
   `mix hex.publish --yes`, which publishes the package and its docs.

To retire a bad release, use `mix hex.retire docuconf 0.1.0 invalid --message "..."`
rather than reverting it. Hex allows `mix hex.publish --revert` only within
an hour of publishing.
