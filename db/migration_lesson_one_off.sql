-- Explicit "one-off" flag on each lesson, replacing the fragile "slot_id IS NULL" inference.
-- A lesson is one_off = true when it is NOT part of a recurring arrangement (a manual ad-hoc
-- add), and false when it was generated from / logged against a weekly slot. Storing it on the
-- lesson means deleting a slot template can no longer mislabel real recurring lessons as one-off.
alter table lessons add column if not exists one_off boolean not null default false;

-- Backfill from the best signal available for existing rows: no slot link => one-off.
-- (Rows whose slot_id was wrongly nulled by an old slot deletion will come out as one_off=true
--  here; fix those per-student afterwards with a targeted update.)
update public.lessons set one_off = (slot_id is null);
