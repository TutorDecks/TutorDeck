// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
// Supabase project values for TutorDeck.
// These (URL + publishable key) are the ONLY place you set credentials.
// Find them in Supabase → Settings → API Keys (or the Connect dialog).
// The publishable key is SAFE to commit publicly — Row Level Security is
// what protects your data, not the secrecy of this key.
// ---------------------------------------------------------------------
window.TLENG_CONFIG = {
  SUPABASE_URL:      "https://rnjvswkejbrhbaytutai.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_IKUtlGhnwJT0Hld5A8cglw_0iF6Y5J9",
  // Google OAuth client ID for Calendar sync (public, safe to commit — like the anon key).
  GOOGLE_CLIENT_ID:  "560106211240-ip7sv5rrpc71f6jenmod34e13i94rdjg.apps.googleusercontent.com",
  // Cloudflare Turnstile SITE key (public). Leave "" to disable the bot check on sign-up.
  // To enable: Cloudflare → Turnstile → Add widget (domain tutordeck.com.sg, "Managed") → copy the Site key here,
  // then Supabase → Authentication → Attack protection → Enable Captcha → Turnstile → paste the SECRET key there.
  TURNSTILE_SITE_KEY: ""
};