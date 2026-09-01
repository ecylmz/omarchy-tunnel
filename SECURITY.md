# Security Policy

## Scope

Omarchy Tunnel manages WireGuard connection profiles through NetworkManager. Reports involving command execution, authorization bypass, unintended profile mutation, leakage of WireGuard private keys, unsafe file import, or shell/argument injection are security-sensitive.

## Design invariants

Changes should preserve these invariants:

- Never add passwordless `sudo` / `sudoers` rules.
- Never invoke `wg-quick` with elevated privileges.
- Never pass user-controlled values through `bash -c`, `sh -c`, `eval`, or equivalent shell interpolation.
- Use validated NetworkManager UUIDs for profile mutations.
- Do not print, persist, or expose imported configuration contents or WireGuard private keys.
- Open imports with no symlink following, require a regular file, enforce the 64 KiB ceiling while copying, and validate/import the same private temporary copy.
- Reject wg-quick command hooks (`PreUp`, `PostUp`, `PreDown`, `PostDown`) in that exact copy before import.
- Bound retained child stdout/stderr and give every external process an outer deadline.
- Identify a new profile from the import operation's UUID and verify its UUID/type before every mutation or rollback action.
- Let NetworkManager/Polkit own authorization decisions.
- If import identity or post-import hardening cannot be proven, deactivate/restrict and remove transaction candidates instead of leaving an unexpectedly permissive profile.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository when available. Do not include real WireGuard private keys or production configuration files in a report; use redacted or synthetic examples.
