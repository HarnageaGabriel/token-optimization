# Security Policy

## Supported versions

Everything is maintained on `main`. There are no release branches, so fixes go
there and nowhere else.

## Reporting a vulnerability

Please don't open a public issue for a security problem.

Use GitHub private reporting instead: **Security > Report a vulnerability** on
this repository. If that isn't available to you, write to
`gabriel.harnagea06@gmail.com` with `SECURITY` in the subject.

Useful things to include:

- what the issue is and where it lives, ideally down to the file or the command
- how to reproduce it, with a minimal example if you have one
- what an attacker gets out of it, and what they need in place first

I'll try to acknowledge within 7 days and give you a status update within 30.
This is a personal project maintained by one person, so please leave some room
for a fix before going public.

## Scope

The configuration and workflow examples here are written to be read and adapted.
Running them as-is against a production system isn't the intended use. Reports
about hardcoded credentials, privilege escalation through a workflow, or an
example that is unsafe by default are all welcome.
