-- Undo for migration_payment_fix.sql: deliberately a no-op.
-- The migration only replaces the body of centre_record_payment with a corrected copy. The older body fails on Supabase ("DELETE requires a WHERE
-- clause", SQLSTATE 21000), so putting it back would only bring the bug back. To remove the function altogether run migration_centre_payments_down.sql.
select 1;
