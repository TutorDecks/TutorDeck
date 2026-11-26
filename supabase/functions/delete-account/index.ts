// Supabase Edge Function: delete-account — RETIRED.
// Account deletion now lives in api/delete-account.js (Vercel), because deleting a tutor means more than deleting the login:
// their organisation's rows, the audit log, Stripe, stored files and the Google token all have to go too, and the Stripe
// key only exists in Vercel. This stub stays only so an old cached page calling it gets a clear answer instead of
// deleting just the login. (Once deployed, you can also delete the function in the Supabase dashboard.)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve((req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  return new Response(JSON.stringify({ error: "moved", message: "Use /api/delete-account (reload the page)." }), {
    status: 410,
    headers: { ...cors, "Content-Type": "application/json" },
  });
});
