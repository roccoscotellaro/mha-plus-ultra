// Brani musicali privati del master, nel bucket "musica" (non pubblico).
// Ogni azione richiede il PIN del master. L'elenco dei brani sta in docs: stato/musica.
// Azioni (campo "action" nel form): list, upload, update, delete.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MAX = 30 * 1024 * 1024;
const BUCKET = "musica";
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Track = { id: string; name: string; cat: string; size?: number; type?: string; at?: number };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Metodo non consentito" }, 405);
  try {
    const fd = await req.formData();
    const action = String(fd.get("action") || "list");
    const pin = String(fd.get("pin") || "");
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });
    const { data: ck, error: ckErr } = await sb.rpc("check_pin", { p_pin: pin });
    if (ckErr) return json({ error: "Verifica PIN non riuscita" }, 500);
    if (!ck?.ok) return json({ error: ck?.err === "bloccato" ? "Troppi tentativi" : "PIN errato" }, 403);

    const readList = async (): Promise<Track[]> => {
      const { data } = await sb.from("docs").select("data").eq("col", "stato").eq("id", "musica").maybeSingle();
      return Array.isArray(data?.data?.tracks) ? data!.data.tracks : [];
    };
    const writeList = async (tracks: Track[]) => {
      const { error } = await sb.from("docs").upsert({ col: "stato", id: "musica", data: { tracks, updatedAt: Date.now() } });
      if (error) throw new Error(error.message);
    };

    if (action === "list") {
      const tracks = await readList();
      if (!tracks.length) return json({ tracks: [] });
      const { data: signed, error } = await sb.storage.from(BUCKET).createSignedUrls(tracks.map((t) => "t/" + t.id), 60 * 60 * 12);
      if (error) return json({ error: error.message }, 500);
      const map = new Map((signed || []).map((s) => [s.path, s.signedUrl]));
      return json({ tracks: tracks.map((t) => ({ ...t, url: map.get("t/" + t.id) || "" })) });
    }

    if (action === "upload") {
      const file = fd.get("file");
      if (!(file instanceof File)) return json({ error: "Nessun file" }, 400);
      if (!/^audio\//.test(file.type) && !/\.(mp3|m4a|ogg|wav|aac|flac)$/i.test(file.name)) return json({ error: "Formato non supportato" }, 400);
      if (file.size > MAX) return json({ error: "File troppo grande (max 30 MB)" }, 400);
      const id = crypto.randomUUID().replace(/-/g, "");
      const { error: upErr } = await sb.storage.from(BUCKET).upload("t/" + id, file, {
        contentType: file.type || "audio/mpeg",
        cacheControl: "31536000",
        upsert: false,
      });
      if (upErr) return json({ error: upErr.message }, 500);
      const t: Track = {
        id,
        name: String(fd.get("name") || file.name).slice(0, 120),
        cat: String(fd.get("cat") || "scena").slice(0, 20),
        size: file.size,
        type: file.type,
        at: Date.now(),
      };
      const tracks = await readList();
      tracks.push(t);
      await writeList(tracks);
      return json({ track: t });
    }

    if (action === "update") {
      const id = String(fd.get("id") || "");
      const tracks = await readList();
      const t = tracks.find((x) => x.id === id);
      if (!t) return json({ error: "Brano non trovato" }, 404);
      if (fd.get("cat")) t.cat = String(fd.get("cat")).slice(0, 20);
      if (fd.get("name")) t.name = String(fd.get("name")).slice(0, 120);
      await writeList(tracks);
      return json({ track: t });
    }

    if (action === "delete") {
      const id = String(fd.get("id") || "");
      await sb.storage.from(BUCKET).remove(["t/" + id]);
      const tracks = (await readList()).filter((x) => x.id !== id);
      await writeList(tracks);
      return json({ ok: true });
    }

    return json({ error: "Azione sconosciuta" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
