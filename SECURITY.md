# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/docuconf/docuconf-elixir/security/advisories/new)). Do not open a public issue, pull
request or discussion for a suspected vulnerability.

Include what you can of:

- the affected version of the `docuconf` package, and your Elixir and OTP versions;
- what an attacker can do, and what they need first;
- steps or a minimal declaration, contract or environment that reproduces it.

We work on the fix in a private security advisory, credit you in it unless you prefer otherwise, and publish the
advisory when a fixed release is out.

## Response targets

| | |
|---|---|
| Acknowledge the report | within 3 business days |
| First assessment (confirmed or not, severity) | as soon as we can reproduce it, and we keep you updated in the advisory |
| Fix | released as a patch to the supported version, then the advisory is published |

## Supported versions

Security fixes go to the latest minor release, as a new patch release (see [RELEASING.md](RELEASING.md)):

| Artifact | Tag | Supported |
|---|---|---|
| Elixir SDK (the `docuconf` Hex package, and its tarball on the GitHub Release) | `v*` | latest minor |

**During the beta, only the latest release is supported.** Upgrade to it to get a fix.

## Scope

In scope: the Elixir SDK in [`lib`](lib), for example a secret value that reaches an error message, a log line,
`inspect/2` output or the termination log, a value that passes the boot checks but should not, or a contract export
that drops a constraint.

Out of scope: the example application under [`examples`](examples), vulnerabilities in dependencies that docuconf does
not make reachable (report those upstream), and issues in a platform or cluster that only arise from its own
misconfiguration. The docuconf CLI, the Go SDK, the Helm chart and the CUE meta-schema live in
[docuconf-go](https://github.com/docuconf/docuconf-go), and other language SDKs in their own repositories; each follows
its own policy.
