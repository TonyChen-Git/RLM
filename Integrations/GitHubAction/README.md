# LumaChat GitHub Action

This Node 20 action runs `review`, `analyze`, or `comment` through one explicitly
configured LumaChat App Server. All three operations create a `plan` task with
the exact `backend_id` and `model_id`; there is no model-provider client and no
cloud fallback in the action.

The runner must already be able to reach the App Server and its checkout must
contain both commits. A self-hosted runner is the usual loopback setup. Remote
servers require `allow_remote: "true"`, HTTPS, and an operator-controlled
network/TLS boundary. `server_token` is always required and should be provided
from a GitHub secret.

```yaml
- uses: owner/lumachat/integrations/GitHubAction@ref
  with:
    server_url: ${{ secrets.LUMACHAT_APP_SERVER_URL }}
    server_token: ${{ secrets.LUMACHAT_APP_SERVER_TOKEN }}
    allow_remote: "true"
    backend_id: ${{ vars.LUMACHAT_BACKEND_ID }}
    model_id: ${{ vars.LUMACHAT_MODEL_ID }}
    operation: comment
    github_token: ${{ github.token }}
```

The action obtains the requested base/head diff with `git` argv (never a shell),
uses a scrubbed subprocess environment whose only temporary location is a
non-symlink `tmp` directory inside the canonical repository, bounds all
input/output, marks repository content as untrusted in the prompt, and polls the
same task until completion. The create response and every poll must repeat the
exact task ID, workspace, Plan mode, backend, and model selected by the user.
`awaiting_approval`, `paused`, `cancelled`, `failed`, and `step_limit` fail the
job. On approval, failure, polling error, unsupported state, or timeout, the
action also makes one best-effort stop request for that exact task; a cleanup
error never masks the original failure. Comment publication occurs only after
`completed` and uses only `result.content`; reasoning summaries are never
published.

`base_sha`, `head_sha`, and `issue_number` accept only closed identifiers;
`issue_number`, when provided, overrides event metadata. Backend and model IDs
are exact constraints rather than preferences. If task submission, result
extraction, comment publication, or output writing fails after creation, the
same task receives a best-effort stop and the job fails. The action has no
approval call and no direct provider or cloud client.

Outputs are `task_id`, `status`, and `report`. The example workflow is
[`../../.github/workflows/lumachat-review.yml.example`](../../.github/workflows/lumachat-review.yml.example).
