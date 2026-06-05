---
type: epic
id: 013
title: Project-management documentation & process
status: in-progress
milestone: v1.3.0
issue: 8
opened: 2026-05-29
shipped:
tags: [docs, process]
---

# Epic 013: Project-management documentation & process

## Why
Issue #8 (加入更詳細的專案管理文件): the project is built feature-by-feature with no overview
or forward planning, and wants proper PM docs (vision, roadmap, future planning). The issue
notes the guiding principle: GitHub Issues is a **ticket inbox** for user bug/feature reports,
not the place for project management.

## Goal
A plain-text, git-versioned PM system: `epics/*.md` are the source of truth; [[roadmap]] and
[[backlog]] are Dataview views over them; [[scope]] carries the vision; [[process]] documents
how work flows; GitHub stays a clean inbox that links into the markdown plan.

## Stories
- [x] Epic template + one epic file per issue (this collection)
- [x] [[process]] — the management system (axes, lifecycle, triage policy, DoD)
- [x] [[playbook]] — step-by-step operating recipes (triage, ship, drop, scope-change ripple)
- [x] [[roadmap]] / [[backlog]] — Dataview views
- [x] Vision section in [[scope]]; freeze banner on [[phases]]
- [x] `.github` issue/PR templates; `.gitignore` for `.obsidian/`
- [x] CLAUDE.md: docs-first links + PM standing rules
- [ ] GitHub: labels, milestones (v1.3.0–v1.5.0), triage of all open issues
- [ ] PR closing #8

## Decisions made along the way
- **Single-collection model:** every feature/idea is one epic file; roadmap/backlog are
  projections via Dataview, never hand-maintained. Chose this over separate hand-edited
  roadmap/backlog lists so the views can't drift from reality.
- **Obsidian-flavored markdown** (wikilinks + frontmatter + Dataview) over vanilla: richer
  linking/querying; accepted that GitHub renders query blocks as code and wikilinks as text.
- **Froze [[phases]]** rather than continuing to append per-issue phases — continues the
  direction set by commits `50b4557` / `2f72b4c`.

## Acceptance criteria
- [x] Docs exist and cross-link; epic frontmatter is consistent
- [ ] Open issues are labelled, milestoned, and represented by epic files
- [ ] #8 closed via the PR
