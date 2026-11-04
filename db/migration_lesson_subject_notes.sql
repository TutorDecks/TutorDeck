-- =====================================================================
-- Notes per subject for lessons that cover several subjects (e.g. "A-Math G3 + Physics G2").
-- Shape: {"A-Math": {"topics": "...", "homework": "...", "remarks": "..."}, "Physics": {...}}
-- Single-subject lessons leave it empty and keep using topics / homework / remarks as before;
-- multi-subject lessons also write a combined copy into those columns, so exports still read well.
-- Run once in the Supabase SQL editor BEFORE the code that reads it reaches dev (previews share
-- this database). Additive: nothing existing changes.
-- =====================================================================
alter table public.lessons add column if not exists subject_notes jsonb;
