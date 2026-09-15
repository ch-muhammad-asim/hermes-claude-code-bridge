# 🐙 Read-only `gh` wrapper

`gh` is a POSIX-shell wrapper that replaces a GitHub MCP server. It is mounted from a
ConfigMap and symlinked to `/usr/local/bin/gh` in the `hermes` container by a `postStart`
hook, so the agent just runs `gh` normally.

It does two jobs on **every** call.

## 1️⃣ Mints a fresh installation token

GitHub App tokens expire after ~1 hour. A server that mints once at startup begins
returning `401 Bad credentials` an hour later — an intermittent failure that looks like a
GitHub outage. Minting per call (JWT signed with the App key → installation access token)
makes that failure mode impossible.

## 2️⃣ Enforces a read-only allowlist

| Surface | Allowed |
|---|---|
| `repo` `pr` `issue` `run` `workflow` `release` `label` `gist` | `list` · `view` · `diff` · `checks` · `download` · `status` |
| `search` · `status` | pass through |
| `gh api` | `GET`/`HEAD` only; every body/field flag (`-f`, `-F`, `--field`, `--raw-field`, `--input`) denied |

Anything else exits **64** with `blocked by the read-only SRE policy`.

This is defense-in-depth on top of the App's own read-only permissions — belt and braces,
because a misconfigured App scope should not be the only thing between the agent and a
force-push.

## ✅ Validate

Reads work:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- bash -lc 'gh api /rate_limit --jq .resources.core.limit'
```

Writes are refused by the wrapper — exit 64, never reaching GitHub:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- bash -lc 'gh api -X POST /repos/OWNER/REPO/issues; echo "exit=$?"'
```

## 🧷 Notes

- The real `gh` binary is installed by the `init-runtime-tools` init container — latest
  release, resolved and **checksum-verified** against GitHub's published `checksums.txt`.
- With no `hermes-agent-github-app` Secret (it is `optional`), `gh` is unauthenticated.
  The agent is told to say so rather than retry — see `../skills/lead-devops-sre/SKILL.md`.
