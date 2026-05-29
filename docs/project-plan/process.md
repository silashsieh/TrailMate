# How this project is managed

How work flows through TrailMate, and where each kind of thing is written down. If you're an
agent or a contributor, read this before filing, planning, or closing anything.

> **Guiding principle (from issue #8):** GitHub Issues is a *ticket inbox* for user bug reports
> and feature requests. It is **not** the project-management system. The plan lives here, in
> git, as plain text. GitHub is the doorbell; this folder is the plan.

## Three axes — don't conflate them

| Axis | Question | Units |
|------|----------|-------|
| **Scope** (what) | What are we building, and why? | Vision → Epic → Story |
| **Time** (when) | When does it ship? | Milestone = a release (a `vX.Y.Z` git tag) |
| **Size** (how big) | How do we slice the work? | Epic (a feature) → Story (a checkbox) → Task |

A milestone groups *whatever epics are ready by that release* — it doesn't own them. An epic
doesn't own a date; its stories get pulled into whichever milestone catches them.

## Where things live

- **GitHub Issues** — the inbox. User reports and feature requests, in any language (ours are
  zh-Hant). One issue = one report. Triage decides what becomes planned work.
- **`epics/*.md`** — the plan, and the **single source of truth**. Every accepted feature/idea
  is exactly one epic file. Frontmatter (`status`, `milestone`, `issue`) drives everything.
- **[[roadmap]] / [[backlog]]** — *views*, not lists. They are Dataview queries over `epics/`.
  Never hand-edit them to add an item; edit the epic and the view updates itself.
- **[[scope]]** — the Vision (why TrailMate exists) and the Goals / Non-Goals that bound it.
- **[[phases]]** — frozen historical implementation log (Phases 0–13). Not appended to anymore.
- **Milestones** — both a GitHub milestone and, on release, a `vX.Y.Z` git tag.

An accepted issue gets an epic file with its number in `issue:` frontmatter; the issue gets a
link back to the epic. The loop between inbox and plan is closed in both directions.

## Lifecycle of a piece of work

```
Idea/report → Triage → Epic (open) → Stories done via PRs → Release → Epic done
   (issue)                (epic file)   (PR: "Closes #N")    (tag)    (status: done, shipped:)
```

1. **Idea / report** arrives as a GitHub issue (or a thought you drop straight into an epic).
2. **Triage** (see rhythm below) decides: accept, defer, or decline.
3. **Accept** → create `epics/NNN-slug.md` from [[_template]]; set `status`, link `issue:`.
   - Schedule it by setting `milestone:` (it appears in [[roadmap]]).
   - Or leave `milestone:` empty / `status: idea` (it sits in [[backlog]]).
4. **Build** → work the Stories. Each PR uses `Closes #N` and the repo PR convention.
5. **Release** → cut a `vX.Y.Z` tag; set the epic `status: done` and stamp `shipped:`.
   It drops off the active roadmap and appears under "Recently shipped".

### Status values
`idea` (unscheduled thought) · `open` (accepted, not started) · `in-progress` ·
`done` (shipped) · `deferred` (parked, e.g. a scope conflict).

### Routing rule (what shows where)
- `milestone` set and not `done`/`idea` → **roadmap** (grouped by milestone).
- `status: idea`, or no milestone and not done → **backlog**.
- `status: done` → **roadmap → Recently shipped**.

## Triage policy

What to do when something new arrives. The recurring trap is mutating *closed* work — don't.

| Incoming | Action |
|----------|--------|
| **Bug in a shipped feature** | New issue → new `bug`-tagged epic, linked to the original epic. **Never reopen** the closed epic. Severity decides: critical → hotfix out-of-band; normal → next milestone. |
| **Bug in an in-flight epic** | Add it as a Story (checkbox) inside that epic. |
| **Small improvement to a shipped feature** | New `enhancement` epic in the backlog, linked to the original. Prioritized against *everything*, not silently folded into the current epic. |
| **Behavior change / new capability** | It's scope, not "an improvement." New epic; scope it. |
| **Vague wish** | `status: idea` epic in the backlog. Revisit at triage; don't commit. |
| **Many post-ship fixes piling up** | A new "stabilization" epic. Don't resurrect the old one. |
| **Request that conflicts with [[scope]] non-goals** | `status: deferred`, no milestone, with a note. Needs an explicit scope decision before any work (see [[012-multi-device]]). |

**Why never reopen a shipped epic:** "done" must keep meaning "shipped." Reopening rewrites
history and breaks the roadmap/shipped views. Closed epics are the audit trail of what shipped
in each release. Bugs and polish are *new* work that links *back* — they don't reanimate the old.

## Definition of Done

An epic is `done` only when **all** hold:
- Acceptance criteria met.
- Docs updated in the same change (CLAUDE.md rule — `features.md`/`architecture.md`/etc.
  describe the software as it is *now*).
- Shipped under a milestone (a `vX.Y.Z` tag).
- Epic `status: done`, `shipped:` stamped.

If any of these slips, it isn't done — it's `in-progress`.

## Triage rhythm

Solo project, so no ceremony — but a moment to look at the inbox. At each release cut (or
roughly weekly):
- Label new issues (`bug` / `enhancement` / `documentation` / …).
- Turn accepted issues into epic files; link both ways.
- Set or clear `milestone:` on epics; rebalance the next release.
- Prune stale `idea`s.

## Conventions

- **Epic files:** `NNN-kebab-slug.md`, zero-padded, monotonic. Never reuse or renumber an id.
- **Commits:** Conventional Commits (see CLAUDE.md). **PRs:** `## Summary` + bullets +
  `Closes #N` + the Claude Code footer (see CLAUDE.md "User-expressed preferences").
- **Language:** docs are English; GitHub issues stay zh-Hant (the owner's locale).

## Obsidian usage

These docs form an Obsidian vault (vault root = repo root).
- **Required:** the **Dataview** community plugin — without it, [[roadmap]] and [[backlog]]
  show their query blocks as raw code instead of live tables.
- **Optional:** the **Tasks** plugin for a cross-file checkbox view.
- `[[wikilinks]]` resolve inside Obsidian and power the backlinks panel. On GitHub they render
  as literal text and Dataview blocks render as code — an accepted tradeoff; the prose around
  them still reads fine.
- `.obsidian/` (workspace state) is gitignored.
