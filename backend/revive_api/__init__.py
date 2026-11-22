"""Backend for the 闻笺 app, M2 slice 1: accounts (K1), device registry (A4b), feedback (O1b).

Contracts: docs/prd.md §7 (API) and §8 (data model); libraries: docs/adr/012-backend-libraries.md.
The app never calls this before the user signs in, and no device feature depends on it
(CLAUDE.md rule 3).
"""
