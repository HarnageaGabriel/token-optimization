# Security Policy

## Supported versions

This project is maintained on the `main` branch. Fixes land there; there are no
long-lived release branches to back-port to.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Use GitHub's private reporting instead: **Security → Report a vulnerability** on
this repository. If private reporting is unavailable to you, email
`gabriel.harnagea06@gmail.com` with `SECURITY` in the subject.

Please include:

- what the issue is and where it lives (file, line, or command)
- how to reproduce it, ideally with a minimal example
- what an attacker gains, and any preconditions they need

You can expect an acknowledgement within 7 days and a status update within 30.
Please give me a reasonable window to ship a fix before disclosing publicly.

## Scope

Configuration and workflow examples in this repository are meant to be read and
adapted, not run blindly against production. Reports about hardcoded credentials,
privilege escalation through a workflow, or an example that is unsafe by default
are in scope and welcome.
