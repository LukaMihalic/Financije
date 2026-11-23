// =====================================================================
//  Financije – Supabase Edge Function "procitaj-racun"
//  1) Prima sliku ili PDF računa iz aplikacije, šalje ga Claudeu i vraća trgovinu,
//     datum, ukupni iznos i stavke s prijedlogom kategorija.
//  2) mode: "chat" – razgovor "Pitaj Claudea" u aplikaciji: prosljeđuje poruke Claudeu
//     (alate za čitanje unosa izvršava sama aplikacija, s pravima prijavljenog korisnika).
//  Potrebna tajna: ANTHROPIC_API_KEY (Edge Functions -> Secrets)
// =====================================================================

const MODEL = "claude-haiku-5-5"; // jeftin i brz; za teže račune: "claude-sonnet-5-5"
const DAILY_LIMIT = 40;           // najviše računa po korisniku u 24 sata
const QUESTION_LIMIT = 15;        // najviše pitanja u razgovoru po korisniku u 24 sata
const TOOL_CALL_LIMIT = 120;      // dodatni pozivi unutar pitanja (kad Claude čita unose) – zaštita od zloupotrebe
// Tko upiše vlastiti Claude API ključ u aplikaciji (Postavke i ostalo), troši svoj kredit i nema ograničenja.

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
    const serverKey = Deno.env.get("ANTHROPIC_API_KEY");

    // 1) samo prijavljeni korisnici aplikacije
    const auth = req.headers.get("Authorization") || "";
    const apikey = req.headers.get("apikey") || "";
    const who = await fetch(`${url}/auth/v1/user`, { headers: { Authorization: auth, apikey } });
    if (!who.ok) return json({ error: "Nisi prijavljen." }, 401);

    const body = await req.json();
    const chat = body && body.mode === "chat";
    const userKey = typeof body?.user_key === "string" && /^sk-ant-[\w-]{20,}$/.test(body.user_key.trim()) ? body.user_key.trim() : null;
    const key = userKey || serverKey;
    if (!key) return json({ error: "U Supabaseu nedostaje tajna ANTHROPIC_API_KEY." }, 500);

    // 2) dnevno ograničenje (štiti tvoj API kredit) – računi, pitanja i dodatni pozivi broje se odvojeno (stupac kind)
    const h = { Authorization: auth, apikey, "Content-Type": "application/json" };
    const since = new Date(Date.now() - 864e5).toISOString();
    const msgs = Array.isArray(body?.messages) ? body.messages : [];
    const last = msgs[msgs.length - 1];
    const isFollowUp = chat && last && Array.isArray(last.content) && last.content.some((b) => b && b.type === "tool_result");
    const kind = !chat ? "racun" : isFollowUp ? "alat" : "pitanje";
    const count = (extra) => fetch(`${url}/rest/v1/ai_usage?select=id&created_at=gte.${since}${extra}`, {
      headers: { ...h, Prefer: "count=exact", Range: "0-0" },
    });
    if (!userKey) {
      let cnt = await count(`&kind=eq.${kind}`);
      const hasKind = cnt.ok;                     // stara baza bez stupca kind: računi kao prije, pitanja bez brojanja
      if (!hasKind && !chat) cnt = await count("");
      if (cnt.ok) {
        const used = parseInt((cnt.headers.get("content-range") || "*/0").split("/")[1] || "0");
        if (kind === "racun" && used >= DAILY_LIMIT) return json({ error: `Potrošeno je dnevno ograničenje od ${DAILY_LIMIT} računa.`, limit: true }, 429);
        if (kind === "pitanje" && used >= QUESTION_LIMIT) return json({ error: `Potrošeno je dnevno ograničenje od ${QUESTION_LIMIT} pitanja.`, limit: true }, 429);
        if (kind === "alat" && used >= TOOL_CALL_LIMIT) return json({ error: `Potrošeno je dnevno ograničenje od ${QUESTION_LIMIT} pitanja.`, limit: true }, 429);
        await fetch(`${url}/rest/v1/ai_usage`, { method: "POST", headers: h, body: hasKind ? JSON.stringify({ kind }) : "{}" });
      }
    }

    // 3a) razgovor "Pitaj Claudea"
    if (chat) {
      const { system, messages, tools } = body;
      if (!Array.isArray(messages) || !messages.length || JSON.stringify(body).length > 250000) return json({ error: "Neispravan upit." }, 400);
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: 1500,
          system: String(system || "").slice(0, 60000),
          messages,
          ...(Array.isArray(tools) && tools.length ? { tools: tools.slice(0, 8) } : {}),
        }),
      });
      const d = await r.json();
      if (!r.ok) return json({ error: (userKey ? "Tvoj Claude ključ: " : "Claude API: ") + (d?.error?.message || r.status) }, 502);
      return json({ content: d.content || [], stop_reason: d.stop_reason, usage: d.usage, model: MODEL });
    }

    // 3b) slika i kategorije iz aplikacije
    const { image, media_type, categories } = body;
    if (!image) return json({ error: "Nema slike ni datoteke." }, 400);
    const isPdf = media_type === "application/pdf";
    const cats = Array.isArray(categories) && categories.length ? categories.slice(0, 60) : null;

    const tool = {
      name: "spremi_racun",
      description: "Sprema podatke pročitane s računa.",
      input_schema: {
        type: "object",
        properties: {
          is_receipt: { type: "boolean", description: "Je li na slici račun." },
          store: { type: "string", description: "Naziv trgovine, objekta ili izdavatelja računa, kratko (npr. 'Konzum', 'A1', 'HEP')." },
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
      "Ovo je račun: fiskalni račun iz trgovine ili elektronički račun za usluge (internet, mobitel, struja, plin, voda…). " +
      "Pročitaj naziv trgovine ili izdavatelja, datum računa (datum izdavanja, ne rok plaćanja), " +
      "ukupni iznos za plaćanje u EUR i SVE stavke. Kod računa za usluge stavke su usluge i naknade (npr. 'Internet paket', 'Mjesečna naknada'), " +
      "a ukupni iznos je iznos za plaćanje s PDV-om. Ako račun ima i prijenos duga iz prošlog razdoblja, ukupni iznos neka bude samo iznos ovog računa. " +
      "Nazive stavki napiši razumljivo na hrvatskom " +
      "(raspiši očite kratice, npr. 'MLIJ.TR.2,8%' → 'Mlijeko trajno 2,8%'). Cijena stavke je ukupna cijena " +
      "te stavke. Popuste i povrat ambalaže upiši kao zasebne stavke s negativnom cijenom. " +
      (cats ? `Svakoj stavki dodijeli najprikladniju kategoriju s popisa: ${cats.join(", ")}. ` : "") +
      "Ako nešto nije čitljivo, izostavi to umjesto da nagađaš. Ako ovo nije račun, postavi is_receipt na false.";

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
            isPdf
              ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } }
              : { type: "image", source: { type: "base64", media_type: media_type || "image/jpeg", data: image } },
            { type: "text", text: prompt },
          ],
        }],
      }),
    });
    const d = await r.json();
    if (!r.ok) return json({ error: (userKey ? "Tvoj Claude ključ: " : "Claude API: ") + (d?.error?.message || r.status) }, 502);
    const t = (d.content || []).find((b) => b.type === "tool_use");
    if (!t) return json({ error: "Claude nije vratio podatke s računa." }, 502);
    return json({ ...t.input, model: MODEL, usage: d.usage });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
