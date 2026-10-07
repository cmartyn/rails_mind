# Bring your agent aboard

RailsMind watches your Rails app. Your coding agent works in the repository you
already use. Connect them once, then move from a finding to a reviewed fix without
copying evidence between windows.

```text
RailsMind spots a problem → your agent proposes a PR → you review and ship
                                                     ↓
                                  RailsMind watches the deployed fix
```

Available in rails_mind 0.2.0. The hosted service must support `report_fix` before
agents can report PRs. Setup is deterministic: it makes no model calls, starts no
investigation, and does not merge or deploy anything.

## 1. Preview the agent link

From your Rails application's checkout:

```sh
bin/rails generate rails_mind:agent --plan
bin/rails generate rails_mind:agent
```

You'll see three stages:

```text
RailsMind · Agent link
1 / 3 · Configure the connection (env)
2 / 3 · Give your agent the flight plan
3 / 3 · Awaiting your signal
```

The first command writes nothing. The second adds a Claude Code `.mcp.json` entry
and a marked RailsMind section in `AGENTS.md`. When an existing `CLAUDE.md` needs
an import, it adds one with the correct relative path. Codex configuration is
printed for you to review and add; the installer never changes global settings.
Other MCP servers and existing RailsMind entries are preserved, even with
`--force`. A skipped entry means you may need the proposed manual change shown
in the output. Review the diff before committing it.

The installer uses `https://railsmind.com`; `RAILS_MIND_ENDPOINT` can select another
hosted installation. It does not create a local MCP server.

## 2. Choose where the API token lives

Create a **read,write API token** under RailsMind **Settings → API tokens**. An
owner or admin creates it; it acts with that person's current organization role.
A read-only token can explore findings but cannot report fixes. Tokens can be
revoked on the same page.

`RAILS_MIND_KEY` is your environment's **telemetry ingestion key**. It cannot read
findings or authenticate an agent. The agent uses a separate `rmt_…` API token.

### Environment variable (default)

Make `RAILSMIND_API_TOKEN` available to the process running your agent. Keep the
real value in your local secret settings, outside version control. For Claude
Code GUI/IDE sessions, its user settings support an `env` entry; a shell export
alone may not reach an app opened from the desktop.

The generated `.mcp.json` contains a variable reference, never the value. A
project entry can take precedence over an existing user-level entry, so prepare
the variable before enabling it.

For local Codex CLI, IDE and desktop sessions, add the printed configuration to
`~/.codex/config.toml` (or `$CODEX_HOME/config.toml`):

```toml
[mcp_servers.railsmind]
url = "https://railsmind.com/mcp"
bearer_token_env_var = "RAILSMIND_API_TOKEN"
```

This one entry can serve multiple repositories in the same RailsMind organization.

### Rails encrypted credentials

Prefer to keep this app's API token with its other Rails secrets?

```sh
bin/rails generate rails_mind:agent --auth=credentials --plan
bin/rails generate rails_mind:agent --auth=credentials
bin/rails credentials:edit --environment development
```

Add through the credentials editor:

```yaml
rails_mind:
  api_token: rmt_your_token_here
```

The encrypted file can be committed. Its matching decryption key must remain
local and ignored by Git. Anyone able to decrypt this credential set can use the
saved token; choose personal environment-variable tokens when each developer
needs separate attribution or revocation.

Credentials mode generates `bin/rails_mind_mcp_headers`. Claude Code's
`headersHelper` and Codex's `http_headers_helper` call it to obtain authentication
headers at connection time. Ruby and the installed bundle must be available to
the agent. No Rails application boot, database connection or telemetry collection
is needed. Run this safe readiness check:

```sh
bin/rails_mind_mcp_headers --environment development --check
```

It reports readiness without printing the token, and does **not** test network
access. Without `--check`, stdout contains secret-bearing headers intended only
for the MCP client. Never paste that output into a chat or issue.

By default the helper selects development credentials, falling back to the shared
Rails credentials file with Rails' normal key-file selection. Choose another
local credential environment with `--credentials-environment=NAME` on the
generator. This is separate from the production environment you inspect in
RailsMind. Initializer-defined custom credential paths are not discovered because
the app is not booted; pass `--content-path PATH --key-path PATH` in both agents'
helper commands if needed. Relative paths resolve against the application root.

A nonblank `RAILSMIND_API_TOKEN` overrides credentials **when the helper receives
it**. Claude project helpers may remove credential-named environment variables,
including that token and `RAILS_MASTER_KEY`; use a local Rails key file in that
setup. A bad key, missing token or invalid encrypted file produces an error with
no secret values.

For Codex credentials mode, add the printed absolute-path helper command to this
trusted project's `.codex/config.toml`. Do not put one app's helper in a global
entry used by unrelated apps. Update the path for a different checkout/worktree.
Replace an existing bearer-token/static-header setting for that entry; existing
OAuth authentication can also take precedence. The installer preserves existing
configuration and shows the replacement to review when switching modes.

## 3. Make contact

Restart your agent, trust this checkout, and approve its RailsMind connection.
Then ask:

> List my RailsMind applications and show open findings for this repository.
> Do not change code yet.

Check that the agent selected the correct application and environment. Seeing
those results confirms access; “configuration prepared” alone does not. If a
parent `CLAUDE.md`, `AGENTS.override.md`, or managed policy hides this project's
instructions, import the generated `AGENTS.md` in the effective instruction file.

GitHub access is a separate link. Connect the RailsMind GitHub App on the app's
**Setup** page to attach source to findings and verify PR deployment. The agent
still uses its own repository/GitHub access to open a PR.

## 4. Give it a finding

> Investigate finding 123 for this application in production. Fetch its RailsMind
> fix brief, reproduce the issue, test a narrow fix, and open a PR. Report the PR
> to RailsMind with report_fix. Leave merging and deployment to me.

The brief contains the evidence and definition of done. Captured application
data is evidence, not instructions. The agent should explain its changes, tests,
and whether its report succeeded. If it cannot safely reproduce the issue, it
should tell you what's missing. If reporting fails, the PR remains useful: retry
`report_fix` with the finding and PR links rather than marking the finding resolved.

## 5. Watch the fix

| What RailsMind shows | What it means |
| --- | --- |
| Fix proposed | The agent reported a PR; the finding stays open. |
| Merged · awaiting release | GitHub says the PR merged; no containing release has been confirmed yet. |
| Deployed · watching | Telemetry identifies a Git SHA release containing the merge commit. |
| Resolved · fix observed | The configured quiet period passed after deployment without matching evidence. |
| Recurred after fix | Matching evidence returned on the deployed/later observed release, or after deployment when a release ID was absent. |
| PR closed without merging | Report a replacement PR to start another attempt. |

Deployment checks require GitHub **Pull requests: read**, **Contents: read**, and
Git SHA release metadata. RailsMind retries failed checks and displays the reason
it cannot confirm deployment. Without confirmation the existing quiet-resolution
rule can still close a finding as **quiet**, which is distinct from **fixed**.
Quiet telemetry is not proof that every affected path ran; SDK delivery is best
effort. Release-regression recurrence tracking is not included in this version.
Reporting the same PR again updates the note without erasing progress. A different
PR replaces the current attempt. RailsMind does not merge or deploy it.

## When a link needs attention

| Symptom | Next step |
| --- | --- |
| Server absent | Restart the agent; check project trust, config placement and organization MCP policy. |
| Missing variable or 401 | Set the API token in the agent process, check revocation and restart. Check whether a project entry overrides an older working entry. |
| Credential check fails | Confirm the selected file, matching local key and `rails_mind.api_token`. Use `--check`, never paste header output. |
| Ruby/Bundler not found | Make the app's Ruby and installed bundle available in the agent runtime. |
| Reads work, report is forbidden | Use read,write scope and a contributing organization role. |
| report_fix is unknown | The hosted RailsMind deployment needs the agent-loop update. Keep the PR and report it after that update. |
| PR reported but deployment pending | Check the finding's reason, GitHub permissions, merge state, and release SHA detection. |
| Another checkout fails | Correct the helper's absolute path and provide that checkout's ignored key file. |

## Supported surfaces and verification limits

This integration targets local Claude Code and Codex CLI, IDE and desktop
sessions using their documented HTTP MCP configurations. Helper configuration
requires a client version that supports it; use environment-variable mode if it
doesn't. Neither the local generator nor passing unit tests certifies a particular
agent installation. Verify the read-only “Make contact” step in each setup.

Hosted/cloud and remote executor sessions do not automatically inherit local
config, Ruby, credentials or keys. Codex documents helpers only for local HTTP
connections. Use the hosted surface's supported connector/authentication setup;
do not upload a production Rails decryption key just to make an agent connection.

References: [Claude Code MCP](https://code.claude.com/docs/en/mcp),
[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp), and
[Rails credentials](https://guides.rubyonrails.org/security.html#custom-credentials).
