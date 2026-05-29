# Documentation

## For users

- [Quick Start](quick-start.md) — install the DMG or build from source, pair an iPhone, first teleport

## Technical

- [Architecture](technical/architecture.md) — project structure, layer diagram, process topology, daemon protocol, coordinate math
- [Tech Stack](technical/tech-stack.md) — framework choices and target versions
- [Features](technical/features.md) — single inventory of shipped features, plus dropped/deferred items
- [Technical Decisions](technical/decisions.md) — key decisions D1–D8 and rationale

## Project Plan

- [Scope](project-plan/scope.md) — vision, goals, and non-goals
- [Process](project-plan/process.md) — how work is planned, tracked, and triaged (start here)
- [Roadmap](project-plan/roadmap.md) — scheduled epics by milestone + recently shipped
- [Backlog](project-plan/backlog.md) — triaged but unscheduled / deferred ideas
- [Epics](project-plan/epics/) — one file per feature/idea; the planning source of truth
- [Implementation Phases](project-plan/phases.md) — frozen historical build log (Phases 0–13)
- [Risks & Mitigations](project-plan/risks.md) — risk register
- [Testing Strategy](project-plan/testing.md) — unit, integration, and manual smoke tests

The roadmap and backlog are **Dataview views** over the epic files — they're generated, not
hand-maintained. They're best viewed in [Obsidian](https://obsidian.md) (vault root = repo
root) with the Dataview plugin installed; on GitHub the query blocks render as code and each
page carries a static prose snapshot for reference. See
[Process § Obsidian usage](project-plan/process.md#obsidian-usage).

## For contributors and Claude agents

Coding conventions, do/don't rules, decision heuristics, and quick-reference commands live in the top-level [CLAUDE.md](../CLAUDE.md) — that file is the entry point for any agent (or human) starting work in this repo.
