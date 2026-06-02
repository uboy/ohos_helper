# Runtime Artifacts

This directory is for local runtime outputs only.

Examples:

- ad-hoc `selector_report.json` copies
- ad-hoc `*_tests_to_run.json`
- local diagnostic logs
- temporary helper outputs created while validating the scripts

Rules:

- keep these files out of the repository root
- do not commit runtime outputs unless a task explicitly asks for a checked-in fixture
- prefer creating subdirectories here when one workflow starts producing many files
