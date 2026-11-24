// Settings → "Your plan" (solo tutors): free up to 5 active students, then Solo Pro.
// Shows nothing at all when the billing tables don't exist yet (so it's safe to ship before the migration) or when
// the tutor isn't a solo organisation. Prices live in Stripe; this page only reads status and opens Stripe pages.
(function () {
  "use strict";
  var card = document.getElementById("plan-card");
  if (!card || !window.sb) return;
  var body = document.getElementById("plan-body"), msg = document.getElementById("plan-msg"), orgId = null, plan = null;

  function esc(x) { return String(x == null ? "" : x).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function day(iso) { return iso ? new Date(iso).toLocaleDateString("en-SG", { day: "numeric", month: "short", year: "numeric" }) : ""; }
  function say(t, err) { msg.textContent = t || ""; msg.className = "msg" + (t ? (err ? " err" : " ok") : ""); }
  function daysLeft(iso) { return Math.max(0, Math.ceil((new Date(iso).getTime() - Date.now()) / 86400000)); }

  // the one sentence + the one action for each situation
  function render() {
    var p = plan, used = p.active_students, lim = p.free_limit, html = "", act = "";
    var meter = '<div class="plan-meter" role="img" aria-label="' + used + ' of ' + lim + ' free active students"><i style="width:' +
      Math.min(100, Math.round(used / lim * 100)) + '%"></i></div>';
    if (p.grandfathered) {
      html = '<p class="plan-line"><span class="badge paid">Early tutor</span> Unlimited students, free. Thank you for being here from the start.</p>' +
        '<p class="muted plan-sub">' + used + ' active student' + (used === 1 ? "" : "s") + ' right now.</p>';
    } else if (p.status === "trialing") {
      html = '<p class="plan-line"><span class="badge paid">Solo Pro trial</span> ' + daysLeft(p.trial_end) + ' day' + (daysLeft(p.trial_end) === 1 ? "" : "s") +
        ' left (ends ' + esc(day(p.trial_end)) + '). No card needed until you choose to continue.</p>' +
        '<p class="muted plan-sub">' + used + ' active student' + (used === 1 ? "" : "s") + ' — unlimited on Solo Pro.</p>';
      act = '<button class="btn" data-act="portal">Add a card to continue</button>';
    } else if (p.status === "active" && p.has_pro) {
      html = '<p class="plan-line"><span class="badge paid">Solo Pro</span> ' + (p.cancel_at_period_end ? 'Ends ' : 'Renews ') + esc(day(p.current_period_end)) + '.</p>' +
        '<p class="muted plan-sub">' + used + ' active student' + (used === 1 ? "" : "s") + ' — unlimited.</p>';
      act = '<button class="btn" data-act="portal">Manage plan &amp; card</button>';
    } else if (p.status === "past_due" && p.has_pro) {
      html = '<p class="plan-line" style="color:var(--warn)"><b>Your last payment didn’t go through.</b> Update your card to keep Solo Pro.</p>';
      act = '<button class="btn" data-act="portal">Update card</button>';
    } else {
      var full = used >= lim;
      html = '<p class="plan-line"><b>Free plan</b> — up to ' + lim + ' active students.</p>' + meter +
        '<p class="muted plan-sub">' + used + ' of ' + lim + ' used' + (full ? '. To add another student, upgrade to Solo Pro.' : '.') + '</p>' +
        '<p class="muted plan-sub">Solo Pro: unlimited students — S$14.90 a month or S$149 a year' + (p.status === "canceled" ? "" : ', with a 30-day free trial') + '.</p>' +
        '<label class="plan-int"><input type="radio" name="plan-int" value="monthly" checked> Monthly</label> ' +
        '<label class="plan-int"><input type="radio" name="plan-int" value="yearly"> Yearly <span class="muted">(2 months free)</span></label>';
      act = '<button class="btn' + (full ? ' btn-primary' : '') + '" data-act="checkout">' + (p.status === "canceled" ? "Restart Solo Pro" : "Start 30-day free trial") + '</button>';
    }
    body.innerHTML = html + (act ? '<div style="margin-top:12px">' + act + '</div>' : "");
    card.style.display = "";
    if (location.hash === "#plan-card") card.scrollIntoView({ block: "start" });
  }

  async function call(action, extra) {
    var s = await window.sb.auth.getSession(), jwt = s && s.data && s.data.session && s.data.session.access_token;
    var r = await fetch("/api/billing", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + jwt },
      body: JSON.stringify(Object.assign({ action: action, org_id: orgId }, extra || {})) });
    var d = await r.json().catch(function () { return {}; });
    if (!r.ok) { var e = new Error(d.error || ("http " + r.status)); e.code = d.error; throw e; }
    return d;
  }

  body.addEventListener("click", async function (ev) {
    var b = ev.target.closest("button[data-act]"); if (!b) return;
    b.disabled = true; say("Opening Stripe…");
    try {
      var iv = (body.querySelector('input[name="plan-int"]:checked') || {}).value || "monthly";
      var d = await call(b.getAttribute("data-act"), b.getAttribute("data-act") === "checkout" ? { interval: iv } : {});
      location.href = d.url;
    } catch (e) {
      b.disabled = false;
      say(e.code === "already_subscribed" ? "You already have Solo Pro — refresh this page." :
          e.code === "owner_only" ? "Only the account owner can change the plan." :
          "Billing isn’t available right now. Please try again in a few minutes.", true);
    }
  });

  async function load() {
    // every failure below just leaves the card hidden
    var o = await window.sb.from("organisations").select("id,kind").eq("kind", "solo").order("created_at").limit(1);
    if (o.error || !o.data || !o.data.length) return;
    orgId = o.data[0].id;
    var r = await window.sb.rpc("org_plan_status", { p_org: orgId });
    if (r.error || !r.data) return;
    plan = r.data; render();
    if (/[?&]billing=success/.test(location.search)) say("Thanks — your plan will update in a moment.");
  }
  // sb.auth session is established by app.js before pages run; wait for it, then load
  window.sb.auth.getSession().then(function (s) { if (s && s.data && s.data.session) load().catch(function () {}); });
})();
