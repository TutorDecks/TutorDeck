// Solo pages read and write ONLY the current solo organisation's rows (T12c). Pure logic: no DOM, no network, no storage.
// assets/js/app.js hands in TL.org() ({ id, kind, role, name }) and exposes these as TL.scope / TL.orgFields / TL.orgId.
// Rules (hard requirements, tested in tests/org-scope.test.js):
//   * solo organisation with a known id  -> reads get `org_id = <id>` (or org_id IS NULL: see NULL_IS_MINE) and inserts carry org_id;
//   * id unknown (null: the organisation tables are missing, as on LIVE today), a centre, or anything odd -> NO filter and no extra
//     field: exactly what the pages did before, so no solo tutor can lose a row because of a doubt or an error.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.OrgScope = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // T12 plan section 7: until a preview shows ZERO rows with a null org_id, a null counts as "mine". Every business row is stamped by
  // the migration backfill and by org_row_guard on insert, and RLS already keeps other people's rows out of sight, so a null row can
  // only be the person's own old row. Flip to false once LIVE has been checked.
  var NULL_IS_MINE = true;

  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  // → the current SOLO organisation's id, or null (= "don't filter", the behaviour before this change).
  function soloId(org) {
    try {
      if (!org || org.kind !== "solo" || !org.id) return null;
      var id = String(org.id);
      return UUID.test(id) ? id : null;       // an id that isn't a uuid never goes into a filter string
    } catch (e) { return null; }
  }

  // q: a supabase-js query right after .select(...) (a filter builder). → the same query, narrowed; other filters/order go after it.
  function scope(q, org) {
    var id = soloId(org);
    if (!id || !q) return q;
    try { return NULL_IS_MINE ? q.or("org_id.eq." + id + ",org_id.is.null") : q.eq("org_id", id); } catch (e) { return q; }
  }

  // row (object) or rows (array) about to be inserted → the same with org_id set. Never overwrites an org_id that is already there.
  function fields(rowOrRows, org) {
    var id = soloId(org);
    if (!id) return rowOrRows;
    function one(r) { return (r && typeof r === "object" && !r.org_id) ? Object.assign({}, r, { org_id: id }) : r; }
    return Array.isArray(rowOrRows) ? rowOrRows.map(one) : one(rowOrRows);
  }

  // Pages a centre login may open. Everything else is a solo-tutor page.
  var CENTRE_PAGES = ["org", "settings", "tutor", "centre", "centre-students", "centre-attendance", "centre-timetable", "centre-money", "centre-tutor-pay"];

  // → the address to go to, or null to stay. Only a CONFIRMED centre (known id) ever redirects, and never away from its own pages.
  function centreRedirect(org, active) {
    try {
      if (!org || org.kind !== "centre" || !org.id) return null;
      if (!active || CENTRE_PAGES.indexOf(active) >= 0) return null;
      return org.role === "tutor" ? "tutor" : "centre?id=" + encodeURIComponent(org.id);
    } catch (e) { return null; }
  }

  return { NULL_IS_MINE: NULL_IS_MINE, soloId: soloId, scope: scope, fields: fields, centreRedirect: centreRedirect, CENTRE_PAGES: CENTRE_PAGES };
});
