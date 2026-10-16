// PayNow (SGQR / EMVCo) payload builder. No backend needed — pure string + CRC.
// Usage: PayNow.build({ type:'mobile'|'uen', id:'+6591234567'|'53312345A',
//                       amount:67.5, name:'TutorDeck', reference:'INV-0001' })
window.PayNow = (function () {

  // tag-length-value; length is 2-digit, char count
  function tlv(id, val) {
    val = String(val);
    var len = val.length;
    return id + (len < 10 ? "0" + len : "" + len) + val;
  }

  // CRC16-CCITT (poly 0x1021, init 0xFFFF) — EMVCo tag 63
  function crc16(s) {
    var crc = 0xFFFF;
    for (var i = 0; i < s.length; i++) {
      crc ^= s.charCodeAt(i) << 8;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
    }
    var h = crc.toString(16).toUpperCase();
    return "0000".slice(h.length) + h;
  }

  // Normalize a proxy value: SG mobiles must be +65XXXXXXXX; UEN passed through.
  function normalize(type, id) {
    id = String(id || "").trim();
    if (type === "mobile") {
      var digits = id.replace(/[^\d+]/g, "");
      if (digits.indexOf("+65") === 0) return digits;
      if (digits.indexOf("65") === 0 && digits.length === 10) return "+" + digits;
      if (digits.length === 8) return "+65" + digits;
      return digits.charAt(0) === "+" ? digits : "+65" + digits.replace(/^\+?/, "");
    }
    return id.toUpperCase();
  }

  function build(o) {
    var proxy = normalize(o.type, o.id);
    var editable = o.amount == null;        // fixed-amount invoice => not editable

    // Merchant Account Information (template 26)
    var mai = tlv("00", "SG.PAYNOW") +
              tlv("01", o.type === "uen" ? "2" : "0") +
              tlv("02", proxy) +
              tlv("03", editable ? "1" : "0");
    if (o.expiry) mai += tlv("04", o.expiry);  // YYYYMMDD, optional

    var s = "";
    s += tlv("00", "01");                   // payload format
    s += tlv("01", "12");                    // point of initiation: dynamic
    s += tlv("26", mai);
    s += tlv("52", "0000");                  // merchant category code
    s += tlv("53", "702");                   // currency SGD
    if (o.amount != null) s += tlv("54", Number(o.amount).toFixed(2));
    s += tlv("58", "SG");                    // country
    s += tlv("59", (o.name || "NA").slice(0, 25));
    s += tlv("60", "Singapore");             // city
    if (o.reference) s += tlv("62", tlv("01", String(o.reference).slice(0, 25)));
    s += "6304";                             // CRC tag + length, value appended next
    return s + crc16(s);
  }

  return { build: build, crc16: crc16, normalize: normalize, tlv: tlv };
})();