-- Bundle 6: three migrations replace org_validate_settings(jsonb) and two replace centre_invoice_run_rows(); each file carries the CUMULATIVE version of the one before,
-- so applying them in order loses no rule, and each undo hands back the previous link. Run with -v stage=full (all applied) or -v stage=undone (bundle-6 set undone,
-- tutor_own_lessons still applied). Made-up data only.
\set ON_ERROR_STOP on
select set_config('t.stage', :'stage', false);
do $chain$
declare
  stage text := current_setting('t.stage');
  base jsonb := t.centre_settings();
  r record; refused boolean; n int := 0; src text;
begin
  -- the base document is valid
  perform org_validate_settings(base);
  -- (label, document with one bad value, true if the rule must exist at this stage)
  for r in select * from (values
    ('T3 deposit mode (money_settings, base chain)',  jsonb_set(base, '{billing,deposit}', '{"mode":"zzz"}'), true),
    ('T6 timetable editing (tutor_moves, base chain)', jsonb_set(base, '{lessons,timetable_editing}', '"zzz"'), true),
    ('T33 billing.starts_from (import)',               jsonb_set(base, '{billing,starts_from}', '"2019-01-01"'), stage = 'full'),
    ('T7.3 email.mode (invoice_email)',                jsonb_set(base, '{email}', '{"mode":"zzz"}'), stage = 'full'),
    ('T18-4 billing.credits.rule (makeup_credits)',    jsonb_set(base, '{billing,credits}', '{"rule":"zzz"}'), stage = 'full')
  ) as c(label, doc, must) loop
    refused := false;
    begin perform org_validate_settings(r.doc); exception when others then refused := true; end;
    if refused <> r.must then raise exception 'FAIL (% stage): "%" refused=% expected=%', stage, r.label, refused, r.must; end if;
    n := n + 1;
  end loop;
  -- the organisation-aware wrapper still calls the 1-argument check (statement matching adds its own rules to it)
  refused := false;
  begin perform org_validate_settings(null::uuid, jsonb_set(base, '{payments,statement}', '{"auto_confirm":"zzz"}')); exception when others then refused := true; end;
  if refused <> (stage = 'full') then raise exception 'FAIL (% stage): statement auto_confirm rule refused=%', stage, refused; end if;
  refused := false;
  begin perform org_validate_settings(null::uuid, jsonb_set(base, '{billing,deposit}', '{"mode":"zzz"}')); exception when others then refused := true; end;
  if not refused then raise exception 'FAIL (% stage): the wrapper lost the 1-argument rules', stage; end if;
  -- the invoice run: tutor_own_lessons' line stays, make-up credits' line comes and goes
  src := pg_get_functiondef('public.centre_invoice_run_rows(uuid,date,date)'::regprocedure);
  if position('price_pending' in src) = 0 then raise exception 'FAIL (% stage): invoice run lost the pending-price rule (tutor_own_lessons)', stage; end if;
  if (position('makeup_billing' in src) > 0) <> (stage = 'full') then raise exception 'FAIL (% stage): make-up line in the invoice run is wrong', stage; end if;
  raise notice 'PASS bundle 6 chain (%): % validator rules + wrapper + invoice run', stage, n;
end $chain$;
