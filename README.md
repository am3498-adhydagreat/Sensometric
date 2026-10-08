# Sensometrix — Workflow v5

Static HTML/JavaScript application with Supabase backend.

Entry point: `index.html`, served through a web server. Keep the existing site's `config.js`.

**Read `PANDUAN_WORKFLOW_V5.md` before installation.** Apply the additive `upgrade-workflow-v5.sql` migration to the existing v4 schema BEFORE deploying this frontend.

New capabilities include project/test grouping, sample catalog and CSV import, participant panels, event scheduling, check-in and serving records, design audit views, and filtered XLSX/PPTX/JSON reports.

Source and export logic have been checked locally. PostgreSQL migration execution and browser acceptance testing remain required on staging; this package has not been deployed to a live site.

Earlier setup notes are retained for historical context. This update does not include the original database bootstrap migration; it is for an already functioning Sensometrix installation.
