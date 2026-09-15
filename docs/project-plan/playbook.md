# Playbook — operating the PM system step by step

> Recipes only. The *rules and why* live in [[process]] — if this file and [[process]] ever
> disagree, [[process]] wins; fix the drift in the same change. Quick orientation:
> `epics/` = source of truth · [[roadmap]] / [[backlog]] = generated views · GitHub Issues =
> inbox.

## One-time setup

1. Open the **`docs/` folder** as an Obsidian vault (not the repo root — the Dataview paths
   depend on it).
2. Install the **Dataview** community plugin (Settings → Community plugins).
3. Open [[roadmap]]: you should see live tables. On GitHub the same blocks render as code —
   read each page's "Static snapshot" section instead.

## Recipe: a new issue arrives (or you have an idea)

1. Label it on GitHub: `bug` / `enhancement` / `documentation`.
2. Triage decision — accept, park, or decline ([[process]] § Triage policy).
3. If accepted or parked, create the epic file:
   - Copy `epics/_template.md` → `epics/NNN-kebab-slug.md`. `NNN` = highest existing + 1,
     zero-padded; never reuse or renumber.
   - Frontmatter: `id`, `title`, `status` (`open` if accepted, `idea` if parked),
     `issue`, `opened` (today).
   - Schedule it by setting `milestone:` (appears in [[roadmap]]) or leave it empty
     (stays in [[backlog]]).
   - Fill **Why** / **Goal** from the issue; mark dependencies with `[[wikilinks]]`.
4. Mirror on GitHub if scheduled: `gh issue edit N --milestone "vX.Y.Z"`.
5. Update the **static snapshot** in [[roadmap]] / [[backlog]] — the one hand-maintained part.
6. Once the epic file exists on `main`, drop a link-back comment on the issue (zh-Hant for
   zh-Hant issues, with the Claude Code attribution if agent-written).

## Recipe: start working an epic

1. Set `status: in-progress` in the epic.
2. Branch per repo convention (`feat/…`, `fix/…`, `docs/…`); tick Stories checkboxes as they
   land.
3. PR: title `<type>: <subject> (closes #N)`; body `## Summary` + bullets + `Closes #N` +
   footer (the PR template pre-fills this).
4. Behavior changes update `features.md` / `architecture.md` / friends **in the same PR**
   (CLAUDE.md rule).
5. Write down significant choices under **Decisions made along the way** while they're fresh.

## Recipe: ship a release

1. `gh workflow run release.yml --ref main -f dry_run=true -f beta=true` — builds, signs,
   notarizes, generates the signed Sparkle feed, and uploads seven-day workflow artifacts
   without creating a release or changing Pages. (`beta` is ignored during a dry run.)
2. After the dry run passes, `gh workflow run release.yml --ref main -f dry_run=false -f beta=true`
   — creates `v<MARKETING_VERSION>`, uploads the notarized DMG plus Sparkle assets while the
   release is a draft, marks it as a GitHub pre-release, publishes it, and then deploys the
   appcast to GitHub Pages. Use `-f beta=false` for a stable GitHub release; both choices use the
   same Sparkle feed unless a separate channel is implemented.
3. Every epic in the release: `status: done`, `shipped: YYYY-MM-DD`.
4. Close the GitHub milestone; create the next one:
   `gh api repos/silashsieh/TrailMate/milestones -f title="vX.Y.Z" -f description="…"`.
5. Refresh the static snapshots: move shipped items in [[roadmap]], prune [[backlog]].
6. Quick triage pass over anything that arrived during the release (first recipe).

## Recipe: a bug is reported against shipped work

1. New GitHub issue, label `bug`. **Never reopen** the shipped epic or its issue.
2. New epic (next id), `tags: [bug]`, linking the original in Why
   (e.g. "Found in [[002-wander-nearby]]").
3. Severity decides the milestone: critical → hotfix out-of-band; normal → next release or
   backlog.

## Recipe: drop or defer an epic

- **Defer** (parked, a decision pending): `status: deferred`, clear `milestone:`, note what
  unblocks it. Shows in [[backlog]].
- **Drop** (the decision was no — e.g. issue closed as not-planned): `status: dropped`, clear
  `milestone:` in the file **and** on the GitHub issue (`gh issue edit N --remove-milestone`),
  add a drop note up top. Shows in **no** view; the file stays as the record.
  Worked example: [[004-read-device-real-gps]].

## Recipe: change scope (goals / non-goals)

1. Edit [[scope]].
2. Walk the **ripple checklist** — each of these can go stale:
   - [ ] Epics referencing the changed goal/non-goal — flip `deferred` ↔ `open`, add a dated
         note (worked example: [[012-multi-device]])
   - [ ] `features.md` § Out of scope
   - [ ] `CLAUDE.md` § Standing constraints
   - [ ] [[process]] worked examples
   - [ ] The Vision paragraphs in [[scope]] itself
   - [ ] Static snapshots in [[roadmap]] / [[backlog]] if any epic moved
3. Record the decision in the affected epic: "Scope decision made YYYY-MM-DD: …".

## Frontmatter reference

| Field | Format / values | Drives |
|---|---|---|
| `type` | always `epic` | Dataview source filter |
| `id` | zero-padded `NNN`, monotonic, never reused | ordering, file name |
| `status` | `idea` · `open` · `in-progress` · `done` · `deferred` · `dropped` | which view shows it ([[process]] § Routing rule) |
| `milestone` | `vX.Y.Z` or empty | roadmap grouping vs backlog |
| `issue` | GitHub issue number or empty | inbox ↔ plan traceability |
| `opened` / `shipped` | `YYYY-MM-DD` | history, shipped sort |
| `tags` | free-form list, e.g. `[positioning]`, `[bug]` | filtering |

## Command cheatsheet

```bash
# Triage
gh issue edit N --add-label enhancement --milestone "v1.4.0"
gh issue edit N --remove-milestone

# Milestones
gh api repos/silashsieh/TrailMate/milestones -f title="v1.6.0" -f description="…"
gh api -X PATCH repos/silashsieh/TrailMate/milestones/<number> -f description="…"

# Lint the epic collection (run from repo root)
grep -L "^type: epic$" docs/project-plan/epics/*.md        # files missing frontmatter
grep -h "^id:" docs/project-plan/epics/*.md | sort | uniq -d   # duplicate ids
```
