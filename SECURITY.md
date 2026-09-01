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
- Reject wg-quick command hooks (`PreUp`, `PostUp`, `PreDown`, `PostDown`) before import.
- Let NetworkManager/Polkit own authorization decisions.
- If post-import hardening fails, prefer rollback over leaving an unexpectedly permissive profile.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository when available. Do not include real WireGuard private keys or production configuration files in a report; use redacted or synthetic examples.
