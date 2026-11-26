-- Scheduled discontinuation: an optional "lessons run until" date per student.
-- Lessons run through end_date INCLUSIVE; after it the student is treated as
-- discontinued (hidden from the Planner, no new lessons generated in the Ledger,
-- no projected blocks on the Calendar). Blank = ongoing. Past lessons/invoices
-- are never touched. Reversible: clear the date to bring the student back.
alter table students add column if not exists end_date date;
