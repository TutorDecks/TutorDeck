// The public invoice page (T4 step S3): opened from the secret link a centre sends a family (pay?t=<token>). No sign-in, no app shell.
// It asks the database for ONE invoice by its token (centre_invoice_public) and draws it read-only: the centre's name, the lines, what is owed and a
// PayNow QR for the centre's own PayNow with the invoice number as the reference. A wrong, expired or replaced link shows a plain "not valid" page.
// Nothing here can change data. Text is always written with textContent, never as HTML.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function money(c) { return window.Money.format(c); }
  function date(iso) { if (!iso) return ""; var d = new Date(iso + "T00:00:00Z"); return d.getUTCDate() + " " + MONTHS[d.getUTCMonth()] + " " + d.getUTCFullYear(); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function row(cls, a, b, small) {
    var r = el("div", cls), l = el("span", cls === "pv-ln" ? "pv-ld" : "", a);
    if (small) l.appendChild(el("small", "", small));
    r.appendChild(l); r.appendChild(el("span", cls === "pv-ln" ? "pv-la" : "", b)); return r;
  }
  // header colour: the centre's own, with text that stays readable on it
  function ink(hex) {
    var m = /^#([0-9a-f]{6})$/i.exec(hex || ""); if (!m) return "#FFFFFF";
    var c = [0, 2, 4].map(function (i) { var v = parseInt(m[1].substr(i, 2), 16) / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    var L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    return (1.05 / (L + 0.05)) >= ((L + 0.05) / 0.0665) ? "#FFFFFF" : "#13233F";
  }
  var CHIP = { issued: ["Awaiting payment", ""], part_paid: ["Part-paid", "warn"], paid: ["Paid", "ok"], overdue: ["Overdue", "bad"], void: ["Cancelled", ""] };

  function invalid() {
    document.title = "Link not valid";
    var m = $("pv-main"); m.textContent = "";
    var c = el("div", "card pv-bad"); c.appendChild(el("h1", "pv-h", "This link isn’t valid any more"));
    c.appendChild(el("p", "pv-sub", "It may have expired or been replaced. Please ask the centre to send you the invoice again."));
    m.appendChild(c);
  }
  function draw(d) {
    var ce = d.centre, inv = d.invoice, pn = d.paynow, chip = CHIP[inv.pay_status] || CHIP.issued;
    document.title = "Invoice " + inv.number + " · " + ce.name;
    var head = $("pv-head"); head.style.background = ce.brand_color || "#0F766E"; head.style.color = ink(ce.brand_color);
    $("pv-centre").textContent = ce.name;
    if (ce.logo_url) { var lg = $("pv-logo"); lg.src = ce.logo_url; lg.hidden = false; }
    var m = $("pv-main"); m.textContent = "";

    var c = el("div", "card pv-card"), top = el("div", "pv-top"), tl = el("div");
    tl.appendChild(el("h1", "pv-h", "Invoice " + inv.number)); tl.appendChild(el("p", "pv-sub", "For " + inv.bill_to));
    top.appendChild(tl); top.appendChild(el("span", "pv-chip " + chip[1], chip[0])); c.appendChild(top);
    var f = el("div", "pv-facts"), a = el("div"), b = el("div");
    a.appendChild(el("span", "", "Issued")); a.appendChild(el("span", "", date(inv.issue_date)));
    b.appendChild(el("span", "", "Due")); b.appendChild(el("span", "", date(inv.due_date)));
    f.appendChild(a); f.appendChild(b); c.appendChild(f);
    var lines = el("div"); lines.setAttribute("role", "list");
    (inv.lines || []).forEach(function (l) {
      var r = row("pv-ln", l.description, money(l.line_cents), (l.student_name ? l.student_name : "") + (l.qty > 1 ? (l.student_name ? " · " : "") + l.qty + " × " + money(l.unit_cents) : ""));
      r.setAttribute("role", "listitem"); lines.appendChild(r);
    });
    c.appendChild(lines);
    var tot = el("div", "pv-tot");
    if (inv.gst_cents) { tot.appendChild(row("", "Subtotal", money(inv.net_cents))); tot.appendChild(row("", "GST", money(inv.gst_cents))); }
    tot.appendChild(row("", "Invoice total", money(inv.total_cents)));
    if (inv.credited_cents) tot.appendChild(row("", "Credit notes", money(-inv.credited_cents)));
    if (inv.paid_cents) tot.appendChild(row("", "Paid", money(-inv.paid_cents)));
    tot.appendChild(row("due", "Amount due", money(inv.balance_cents)));
    c.appendChild(tot); m.appendChild(c);

    if (inv.balance_cents <= 0) {
      var p = el("div", "card pv-card pv-pay"); p.appendChild(el("p", "pv-done", inv.pay_status === "void" ? "This invoice has been cancelled by a credit note. Nothing is due." : "Paid in full. Thank you!"));
      m.appendChild(p);
    } else if (pn) {
      var q = el("div", "card pv-card pv-pay"); q.appendChild(el("h2", "pv-h", "Pay with PayNow"));
      var img = el("img", "pv-qr"); img.alt = "PayNow QR code for " + money(pn.amount_cents); img.width = 220; img.height = 220; q.appendChild(img);
      q.appendChild(el("p", "pv-how", "Open your banking app, choose PayNow, and scan this code. The amount and reference are filled in for you."));
      var dl = el("dl", "pv-ref"), kv = function (k, v) { dl.appendChild(el("dt", "", k)); dl.appendChild(el("dd", "", v)); };
      kv("Amount", money(pn.amount_cents)); kv(pn.type === "mobile" ? "PayNow to (mobile)" : "PayNow to (UEN)", pn.id); kv("Reference", pn.reference);
      q.appendChild(dl); m.appendChild(q);
      try {
        var payload = window.PayNow.build({ type: pn.type, id: pn.id, amount: pn.amount_cents / 100, name: String(ce.name || "").slice(0, 25), reference: pn.reference });
        window.QRCode.toDataURL(payload, { margin: 1, width: 440 }, function (err, url) { if (!err && url) img.src = url; else img.remove(); });
      } catch (e) { img.remove(); }
    } else {
      var o = el("div", "card pv-card"); o.appendChild(el("p", "pv-how", "Please pay " + ce.name + " " + money(inv.balance_cents) + " and quote " + inv.number + " as the reference."));
      m.appendChild(o);
    }
    if (ce.legal_name || ce.address || ce.uen || ce.gst_number) {
      var info = el("p", "pv-foot", [ce.legal_name, ce.uen ? "UEN " + ce.uen : "", ce.gst_number ? "GST reg. " + ce.gst_number : "", ce.address].filter(Boolean).join(" · "));
      m.appendChild(info);
    }
  }
  async function init() {
    var t = new URLSearchParams(location.search).get("t");
    if (!t || !UUID.test(t) || !window.sb) return invalid();
    var r = await window.sb.rpc("centre_invoice_public", { p_token: t });
    if (r.error || !r.data || !r.data.invoice) return invalid();
    draw(r.data);
  }
  init();
})();
