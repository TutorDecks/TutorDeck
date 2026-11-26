# T39 — Vercel builds only `dev` and `main`

Owner decision, 2026-11-26: "vercel should only deploy dev and main".

## Which way was used
**`vercel.json` → `git.deploymentEnabled`** (no script needed). Vercel's Git Configuration page documents:

> Type: `Object` of key branch identifier `String` and value `Boolean`, or `Boolean`. Default: `true`
> Use [minimatch syntax](https://github.com/isaacs/minimatch) to define behavior for multiple branches.
> If a branch matches multiple rules and at least one rule is `true`, a deployment will occur.

So branch globs ARE supported, and an allow-list works as "everything off, two branches on":

```json
"git": {
  "deploymentEnabled": {
    "**": false,
    "main": true,
    "dev": true
  }
}
```

`**` (not `*`) is used because in minimatch `*` does not cross `/`, and our branches are `claude/xyz` and `feature/xyz`.
Because `main` and `dev` also match `**`, the "at least one rule is true" sentence is what lets them still deploy.
The `ignoreCommand` script alternative was not needed.

Note: Vercel reads `vercel.json` from the branch being pushed. This setting takes effect for a branch once it contains it, so
**after this PR merges into `dev`, branches cut from older `dev` still build once** until they merge/rebase `dev`. New branches off `dev` are covered.
For that reason the dashboard fallback below is worth doing too (it applies to every branch at once).

## Dashboard alternative (click by click, applies to all branches immediately)
1. Vercel → project **tutordeck** → **Settings** → **Git**.
2. **Production Branch**: check it says `main`. If not, set it to `main` and Save.
3. Scroll to **Ignored Build Step** → choose **Custom** (older UI: "Run my Bash script").
4. Paste exactly this command and Save (Vercel rule: exit code `0` = skip the build, `1` = build):
   ```
   if [ "$VERCEL_GIT_COMMIT_REF" = "main" ] || [ "$VERCEL_GIT_COMMIT_REF" = "dev" ]; then exit 1; else exit 0; fi
   ```
5. Push any `claude/*` branch to confirm: Vercel shows the deployment as "Canceled / Ignored Build Step".

## What still works / what changes
- **Production**: still built from `main` (Production Branch = `main`). Unchanged.
- **`dev`**: still gets its preview and the stable branch alias for `dev`.
- **Cron** (`/api/billing-cron`, 16:30 UTC): unaffected — crons only run on the production deployment.
- **Database**: nothing changes. config.js still picks the DEV project for every non-production host.
- **PR comments**: PRs from `claude/*` / `feature/*` into `dev` get **no preview link or Vercel comment** any more. Review happens after merge on `dev`.
- **Stripe sandbox webhook (action for the owner)**: it was pointed at a preview of a feature branch (with a Vercel protection-bypass token in the URL). Feature-branch previews will stop updating, so
  **re-point the sandbox webhook endpoint at the `dev` address** (Stripe dashboard → sandbox → Developers → Webhooks → edit endpoint URL to the `dev` branch alias + `/api/stripe-webhook`),
  and when you do, remember the bypass token (CLAUDE.md go-live item: revoke before going live).
- **Seeing a worker's branch on a phone**: merge it into `dev` in an owner-approved bundle; there is no per-branch link any more. Workers test locally.
