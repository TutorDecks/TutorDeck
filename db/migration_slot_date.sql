-- =====================================================================
-- Add slot_date: the recurring-slot occurrence a lesson fulfils.
-- Run once in the Supabase SQL editor. Safe to re-run.
--
-- A lesson has two dates:
--   lesson_date : when it actually happens (moves when you postpone)
--   slot_date   : which weekly occurrence it IS (fixed at generation; never moves)
-- One-off lessons (added by hand, no slot) have slot_date = NULL.
--
-- The calendar uses slot_date to decide "not logged" precisely per occurrence, so a
-- postponed lesson never leaves a phantom and a month-boundary week behaves correctly.
--
-- This is ADDITIVE and backward-compatible: nothing that predates it reads or writes
-- slot_date, so adding the column can't break the current app. Run this BEFORE deploying
-- the code that selects slot_date.
-- =====================================================================
alter table public.lessons add column if not exists slot_date date;

-- Backfill: an existing generated lesson's occurrence is its current date.
-- (Historical lessons already postponed before this ran get their postponed date as
--  slot_date — the true original can't be recovered, but it's correct from here on.)
update public.lessons
   set slot_date = lesson_date
 where slot_id is not null
   and slot_date is null;

-- Speeds up the calendar's per-occurrence lookups (optional but cheap).
create index if not exists lessons_slot_date_idx on public.lessons (tutor_id, slot_date);
