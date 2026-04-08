# AGENTS.md — Contribution Style and Invariants

This document defines the style and invariants for cursor-agent contributions to this repository.

## Core Invariants

1. **Idempotency**: All setup scripts must be idempotent. Running `install.sh` multiple times should produce the same result.

2. **Fail-fast**: Prefer explicit error handling over silent fallbacks. If a required component is missing or misconfigured, fail with a clear error message.

3. **Health checks**: Always validate that components are working after installation. Don't assume success.

4. **Logging**: Use structured logging with clear levels (INFO, WARN, ERROR). Log important state changes and failures.

5. **Diagnostics**: Log capture is automated: `install.sh` runs `collect-logs.sh` on success and on health-check failure; `test-full-cycle.sh` runs it after the manual test step, on health failure, and on SIGINT/SIGTERM (e.g. Ctrl+C). Use `collect-logs.sh` when debugging or gathering state. When adding new components, services, or log sources, update `collect-logs.sh` to include them. Keep the script synchronized with the system's diagnostic needs. Maintain `docs/troubleshooting.md`: when adding or changing components, failure modes, or fixes, update the troubleshooting document so it stays accurate and complete.

6. **Separation of concerns**: Keep streaming session isolated from desktop session. Don't modify user's normal desktop configuration unless explicitly required.

7. **Scientific method**: Employ the scientific method. think critically about if your assumptions are accurate, generate hypotheses and test them with experiments. 

## Code Style

- **Bash scripts**: Use `set -euo pipefail` for strict error handling
- **Comments**: Explain non-obvious configuration choices and why they're needed
- **Variables**: Use uppercase for environment/config variables, lowercase for local variables
- **Functions**: Keep functions focused and testable

## Testing

- All scripts should be testable in isolation
- Use `test-full-cycle.sh` as the primary validation path
- Health checks must be actionable (tell user what's wrong and how to fix)

## Experiments

- Use `scripts/experiment-*.sh` scripts to validate hypotheses before making assumptions about system behavior
- Each experiment script should handle setup, execution, and teardown of test scenarios
- Collect high-signal information to inform decisions rather than assuming system state
- Document hypotheses and findings within the script
- When sudo is required for commands, prompt the user to run it with `sudo ./scripts/experiment-<name>.sh`
- Experiment scripts are temporary diagnostic tools — keep them out of core commits unless they become permanent regression tests

## Configuration Files

- All config files should have comments explaining non-obvious fields
- Use templates with clear variable substitution points
- Document any assumptions about system state

## Systemd Units

- Use `Type=notify` or `Type=simple` appropriately
- Include proper dependencies (`Requires`, `After`)
- Set up log capture via `StandardOutput=journal` and `StandardError=journal`
- Use `User=` directive for service isolation

## Error Messages

- Be specific about what failed
- Provide next steps or references to documentation
- Include relevant system state (e.g., "Xorg log shows: ...")

## Documentation

- **Troubleshooting:** Maintain `docs/troubleshooting.md`. When adding or changing components, failure modes, or fixes, update the troubleshooting document so it stays accurate and complete.
