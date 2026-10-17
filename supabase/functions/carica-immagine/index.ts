// Carica un'immagine nel bucket "immagini".
// Cartella "foto" (foto dei PG): libera per chi ha il link. Cartella "a" (scene, PNG, indizi, TG): serve il PIN del master.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const TIPI = ["image/jpeg", "image/png", "image/webp", "image/gif"];
const MAX = 5 * 1024 * 1024;
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Metodo non consentito" }, 405);
  try {
    const fd = await req.formData();
    const file = fd.get("file");
    const folder = String(fd.get("folder") || "");
    const pin = String(fd.get("pin") || "");
    if (!(file instanceof File)) return json({ error: "Nessun file" }, 400);
    if (folder !== "a" && folder !== "foto") return json({ error: "Cartella non valida" }, 400);
    if (!TIPI.includes(file.type)) return json({ error: "Formato non supportato" }, 400);
    if (file.size > MAX) return json({ error: "File troppo grande" }, 400);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });
    if (folder === "a") {
      const { data, error } = await sb.rpc("check_pin", { p_pin: pin });
      if (error) return json({ error: "Verifica PIN non riuscita" }, 500);
      if (!data?.ok) return json({ error: data?.err === "bloccato" ? "Troppi tentativi" : "PIN errato" }, 403);
    }
    const id = crypto.randomUUID().replace(/-/g, "");
    const path = `${folder}/${id}`;
    const { error: upErr } = await sb.storage.from("immagini").upload(path, file, {
      contentType: file.type,
      cacheControl: "31536000",
      upsert: false,
    });
    if (upErr) return json({ error: upErr.message }, 500);
    return json({ id, path });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
