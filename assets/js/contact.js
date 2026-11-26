// The ONE place TutorDeck's contact address lives (used by the centre Plan tab and by api/billing.js).
// Change it here and nowhere else. Works in the browser (window.TDContact) and in Node (require).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TDContact = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var EMAIL = "tutordeckadmin@gmail.com";
  return {
    EMAIL: EMAIL,
    // mailto link for a centre that wants to set up billing
    centreBillingMailto: function (centreName) {
      var subj = "TutorDeck billing for " + (centreName || "my centre");
      return "mailto:" + EMAIL + "?subject=" + encodeURIComponent(subj);
    }
  };
});
