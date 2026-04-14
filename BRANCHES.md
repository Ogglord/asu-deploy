# BRANCHES configuration

## Background

The ASU server needs a `BRANCHES` environment variable — a JSON object that maps each firmware branch to its display name, package path, and ImageBuilder container tag. This must be kept in sync with whatever the imagebuilder CI actually produces.

Currently `BRANCHES` is updated manually in `.env`. The goal is to automate this by having the imagebuilder CI publish a `branches.json` manifest that this server can consume.

## Required schema

The CI should publish a `branches.json` file with the following structure:

```json
{
  "<branch-key>": {
    "name": "<display name>",
    "enabled": true,
    "path": "<date>_<short-commit-hash>_<branch-key>",
    "path_packages": "<date>_<short-commit-hash>_<branch-key>/packages/{arch}/{feedname}",
    "updates": "dev",
    "targets": {
      "mediatek/filogic": "<branch-key>"
    }
  }
}
```

### Field descriptions

| Field | Example | Description |
|---|---|---|
| `<branch-key>` | `next-r4.8.0.rss.mtk-test6.18` | Key used throughout — matches the upstream pesa branch name and the container image tag suffix |
| `name` | `r4.8.0-test6.18` | Human-readable label shown in LuCI |
| `enabled` | `true` | Whether this branch is served by the ASU API |
| `path` | `2026-04-12_r34722-2fff68cf9a_next-r4.8.0.rss.mtk-test6.18` | Directory name in `pesa1234/MT6000_cust_build` where firmware metadata lives. Format: `YYYY-MM-DD_r<revision>-<short-hash>_<branch-key>` |
| `path_packages` | `<path>/packages/{arch}/{feedname}` | Package path template — same prefix as `path`, ASU substitutes `{arch}` and `{feedname}` at request time |
| `updates` | `dev` | Client-facing update channel label (`dev`, `stable`, `lts`, etc.). Not used by the ASU server itself — passed through to clients (LuCI, owut) for display/filtering purposes |
| `targets` | `{"mediatek/filogic": "<branch-key>"}` | Maps OpenWrt target string to the container image tag suffix; the worker pulls `$BASE_CONTAINER:mediatek-filogic-<branch-key>` |

### Notes on `path`

The `path` value is **not derivable from the branch name or container tag alone** — it includes the build date and the short commit hash from the upstream pesa build. The CI must record this at build time and write it into `branches.json`.

The `path` corresponds to a directory that must exist in `pesa1234/MT6000_cust_build` before the ASU server will successfully serve packages for that branch.

## How many branches to include

Include only the branches that have a corresponding container image published to `ghcr.io/ogglord/openwrt-imagebuilder`. Stale or superseded branches can be omitted or set to `"enabled": false`.

## Suggested publishing location

Publish the file to a stable, unauthenticated URL so the ASU server can fetch it with a plain `curl`. Options in order of preference:

1. **Dedicated branch** in the imagebuilder repo, e.g.:
   ```
   https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/branches.json
   ```
2. **Attached as a release asset** on the latest GitHub Release in that repo.

Option 1 is simpler to consume (static URL, no API call needed to find the latest release).

## How the ASU server will consume it

A script (or systemd timer) on the server will:

1. `curl` the published URL
2. Validate it is valid JSON matching the schema above
3. Overwrite `BRANCHES=<json>` in `.env`
4. Restart the ASU stack (`podman-compose up -d`)

The update can be triggered on a schedule (e.g. every hour) or via a webhook from the imagebuilder CI after a successful build.
