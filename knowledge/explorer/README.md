# Rx2GO Knowledge Explorer

Deployment / knowledge hierarchy:

`BRANCH -> HOT -> ADM`

## Authority

- **ADM** — primary/stable knowledge baseline.
- **HOT** — delta compared with ADM.
- **BRANCH** — temporary delta compared with HOT.

A PASS on HOT does **not** automatically update ADM knowledge.  
ADM baseline changes only after the behavior is actually observed/verified on ADM.

## Storage

- `adm/modules/` and `adm/workflows/` — persistent primary baseline.
- `hot/modules/` and `hot/workflows/` — persistent delta vs ADM.
- `branch/modules/` and `branch/workflows/` — temporary local delta vs HOT.
- `index.json` — persistent ADM/HOT index.
- `branch/index.json` — temporary local branch index.

Explorer data is observed technical/product context, not a source of product requirements.
Jira Description / Expected / Acceptance remains authoritative for expected behavior.


## Full Project mode

`Полный проект — карта + все модули` is a two-stage live discovery mode:

1. Project Mapper uses Playwright MCP to inspect the actual accessible application navigation and saves `project-map.json`.
2. Knowledge Explorer studies every discovered product capability one by one.

This mode is not limited to the predefined priority modules. The module catalog may grow dynamically as the Rx2GO UI changes.

For ADM, the result extends the primary baseline.
For HOT, discovered modules are compared with ADM when a matching baseline module exists.
For BRANCH, discovered modules remain temporary and compare with HOT.

