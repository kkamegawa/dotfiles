---
name: gh-auth-troubleshoot
description: Diagnose GitHub CLI (gh) authentication failures. Use when a gh command reports missing or invalid authentication, "not logged in", "authentication required", HTTP 401, or "Bad credentials", or when gh works differently from git push/pull. Not for running gh normally.
---

# gh authentication troubleshooting

Use this only after a `gh` command has failed with an authentication problem.

## Principles

- `gh` authentication is separate from Git HTTPS credential helpers such as GCM. A working Git helper does not prove that `gh` API calls can authenticate.
- Do not run `gh auth login` or `gh auth refresh` unless the user asks to change credentials.

## Procedure

Run each command below as its own standalone Bash call. Do not prefix it with another command, pipe it, or chain it. The sandbox rule only matches a command that starts with `gh`.

1. Check the stored login state:

   ```bash
   gh auth status
   ```

2. Verify which account the API token actually represents:

   ```bash
   gh api user --jq .login
   ```

   Use this endpoint, not `gh api rate_limit`. The rate limit endpoint succeeds anonymously and is not an authentication check.

3. If status shows a logged-in account but step 2 returns 401, do not conclude that no login exists. An environment token can take precedence over the stored login. Check whether `GH_TOKEN` or `GITHUB_TOKEN` is set. Report only set or unset, never the value.

   bash (macOS/Linux):

   ```bash
   for v in GH_TOKEN GITHUB_TOKEN; do if [ -n "${!v}" ]; then echo "$v set"; else echo "$v unset"; fi; done
   ```

   PowerShell 7:

   ```powershell
   foreach ($v in 'GH_TOKEN','GITHUB_TOKEN') { if (Get-Item "env:$v" -ErrorAction SilentlyContinue) { "$v set" } else { "$v unset" } }
   ```

4. Classify the failure before reporting. Keep these separate:

   | Kind | Typical sign |
   |---|---|
   | Authentication | 401, "Bad credentials", "not logged in", invalid token |
   | Insufficient permissions | 403 with a scope or permission message, token valid but missing scope |
   | Host or network | timeout, DNS or TLS error, proxy refusal |
   | Resource access | 404 or 403 on one repository or org only, while `gh api user` works |

5. Report to the user: which step failed, whether each env variable is set, and the failure class. If credentials need changing, tell the user and let them decide.

## Observed in this environment

- `gh auth status` can report "token in GH_TOKEN is invalid" while `gh api user --jq .login` still succeeds through the agent proxy. Trust the API call result for whether `gh` calls work, and mention the status mismatch to the user.
