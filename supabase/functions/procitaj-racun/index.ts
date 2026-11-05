// =====================================================================
//  Financije – Supabase Edge Function "procitaj-racun"
//  Prima sliku računa iz aplikacije, šalje je Claudeu i vraća trgovinu,
//  datum, ukupni iznos i stavke s prijedlogom kategorija.
//  Potrebna tajna: ANTHROPIC_API_KEY (Edge Functions -> Secrets)
// =====================================================================

const MODEL = "claude-haiku-5-5"; // jeftin i brz; za teže račune: "claude-sonnet-5-5"
const DAILY_LIMIT = 40;           // najviše računa po korisniku u 24 sata

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ error: "U Supabaseu nedostaje tajna ANTHROPIC_API_KEY." }, 500);

    // 1) samo prijavljeni korisnici aplikacije
    const auth = req.headers.get("Authorization") || "";
    const apikey = req.headers.get("apikey") || "";
    const who = await fetch(`${url}/auth/v1/user`, { headers: { Authorization: auth, apikey } });
    if (!who.ok) return json({ error: "Nisi prijavljen." }, 401);

    // 2) dnevno ograničenje (štiti tvoj API kredit)
    const h = { Authorization: auth, apikey, "Content-Type": "application/json" };
    const since = new Date(Date.now() - 864e5).toISOString();
    const cnt = await fetch(`${url}/rest/v1/ai_usage?select=id&created_at=gte.${since}`, {
      headers: { ...h, Prefer: "count=exact", Range: "0-0" },
    });
    if (cnt.ok) {
      const used = parseInt((cnt.headers.get("content-range") || "*/0").split("/")[1] || "0");
      if (used >= DAILY_LIMIT) return json({ error: `Potrošeno je dnevno ograničenje od ${DAILY_LIMIT} računa.` }, 429);
      await fetch(`${url}/rest/v1/ai_usage`, { method: "POST", headers: h, body: "{}" });
    }

    // 3) slika i kategorije iz aplikacije
    const { image, media_type, categories } = await req.json();
    if (!image) return json({ error: "Nema slike." }, 400);
    const cats = Array.isArray(categories) && categories.length ? categories.slice(0, 60) : null;

    const tool = {
      name: "spremi_racun",
      description: "Sprema podatke pročitane s računa.",
      input_schema: {
        type: "object",
        properties: {
          is_receipt: { type: "boolean", description: "Je li na slici račun." },
          store: { type: "string", description: "Naziv trgovine ili ugostiteljskog objekta, kratko (npr. 'Konzum')." },
          date: { type: "string", description: "Datum računa u obliku YYYY-MM-DD, ako se vidi." },
          total: { type: "number", description: "Ukupni iznos za plaćanje u eurima." },
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string", description: "Razumljiv naziv stavke na hrvatskom." },
                qty: { type: "number", description: "Količina (komadi ili kg)." },
                price: { type: "number", description: "Ukupna cijena stavke u eurima (količina × jedinična cijena). Popust je negativan." },
                category: cats ? { type: "string", enum: cats } : { type: "string" },
              },
              required: ["name", "price"],
            },
          },
        },
        required: ["is_receipt", "items"],
      },
    };
    const prompt =
      "Na slici je račun (najčešće hrvatski fiskalni račun). Pročitaj naziv trgovine, datum, " +
      "ukupni iznos za plaćanje u EUR i SVE stavke. Nazive stavki napiši razumljivo na hrvatskom " +
      "(raspiši očite kratice, npr. 'MLIJ.TR.2,8%' → 'Mlijeko trajno 2,8%'). Cijena stavke je ukupna cijena " +
      "te stavke. Popuste i povrat ambalaže upiši kao zasebne stavke s negativnom cijenom. " +
      (cats ? `Svakoj stavki dodijeli najprikladniju kategoriju s popisa: ${cats.join(", ")}. ` : "") +
      "Ako nešto nije čitljivo, izostavi to umjesto da nagađaš. Ako na slici nije račun, postavi is_receipt na false.";

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 3000,
        tools: [tool],
        tool_choice: { type: "tool", name: "spremi_racun" },
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: media_type || "image/jpeg", data: image } },
            { type: "text", text: prompt },
          ],
        }],
      }),
    });
    const d = await r.json();
    if (!r.ok) return json({ error: "Claude API: " + (d?.error?.message || r.status) }, 502);
    const t = (d.content || []).find((b) => b.type === "tool_use");
    if (!t) return json({ error: "Claude nije vratio podatke s računa." }, 502);
    return json({ ...t.input, model: MODEL, usage: d.usage });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
