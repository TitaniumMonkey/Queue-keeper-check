# Security Policy

## Reporting a vulnerability

Email **hello@queuekeeper.dev** with "SECURITY" in the subject. Please include the
version or commit, the database engine and version, and steps to reproduce. Do not open a
public issue for anything that could be exploited.

We will acknowledge a report within 3 business days and keep you updated until it is
resolved. There is no bug bounty.

## Supported versions

The project is pre-1.0. Only the latest release (and `main`) receives security fixes.

| Version | Supported | Notes |
|---|---|---|
| 0.2.x | yes | First public release. |
| 0.1.0 | no | Never tagged or published. `mix queue_keeper.check` started the host application (and therefore Oban) and some queries could run for minutes on large tables. See [docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md), findings QK-01 and QK-02. |

## Scope

In scope: anything in this repository that ships in the package (`lib/`, `mix.exs`),
including the SQL it issues, what it reads and prints, and what it starts.

Out of scope: Oban, Ecto, the database adapters and the database servers themselves
(report those upstream), and the example code in `dev/` and `bench/`, which is never
part of the package.

For what the library does and does not do, the exact SQL it issues, the database
privileges it needs and the measured performance, see
[docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md).
