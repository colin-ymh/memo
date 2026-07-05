// process-memo — 메모 INSERT webhook 백그라운드 처리
// 흐름: memos INSERT → DB Webhook → (여기) 분류(Haiku) + 임베딩(Cohere) → memos UPDATE
//
// 보안/운영 전제:
// - service_role 키는 Supabase가 자동 주입(SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY).
// - 외부 키(ANTHROPIC_API_KEY / COHERE_API_KEY)와 WEBHOOK_SECRET은 Edge Function secrets에만.
// - verify_jwt=false(config.toml). 대신 x-webhook-secret 헤더로 호출자 검증.
// - webhook은 INSERT 전용 + embedding null 가드 → 자기 UPDATE로 재트리거 안 됨(멱등).
// - DB Webhook은 fire-and-forget(재시도 없음) → 함수 내 재시도 + pg_cron 보정 스윕(별도 마이그레이션)으로 보완.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MODEL_HAIKU = "claude-haiku-4-5";
const MODEL_EMBED = "embed-multilingual-v3.0";
const EMBED_DIM = 1024;
const EMBED_VERSION = 1;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const COHERE_KEY = Deno.env.get("COHERE_API_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;

// 분류 규칙 = 안정적이라 캐싱 대상. 카테고리 목록은 바뀌므로 user 메시지에.
const CLASSIFY_SYSTEM = `너는 개인 메모 앱의 카테고리 분류기다.

규칙:
- 사용자의 기존 카테고리 목록을 먼저 본다.
- 기존 카테고리는 메모가 그 주제에 '명확히' 속할 때만 재사용한다.
  언어가 달라도 의미가 같으면 재사용한다(예: "개발"이 있으면 영어 개발 메모도 "개발", 새 "Development" 금지).
- 조금이라도 주제가 다르거나 애매하면 억지로 끼워넣지 말고 새 카테고리를 제안한다(is_new=true).
  '약하게만' 걸치는 기존 카테고리로 욱여넣는 것을 특히 경계한다(예: 마케팅 메모를 "개발"에 넣지 마라).
- 카테고리는 '구체적'으로. 너무 큰 범주("기타"·"일상"·"메모")나 지나치게 포괄적인 이름은 피한다.
- 새 카테고리 이름은 메모와 같은 언어로, 짧고 자연스러운 명사로(대략 2~5자).
- confidence는 '기존 카테고리 재사용'에 대한 확신도다(0~1). **0.7 미만이면 기존에 넣지 말고
  is_new=true로 새 카테고리를 제안하라.** 새 카테고리를 만들 때 confidence는 그 제안의 확신도로 준다.`;

const CLASSIFY_TOOL = {
  name: "classify",
  description: "메모를 카테고리로 분류한다.",
  input_schema: {
    type: "object",
    properties: {
      category: { type: "string", description: "선택/제안한 카테고리 이름" },
      is_new: { type: "boolean", description: "새 카테고리면 true" },
      confidence: { type: "number", description: "확신 0~1" },
      reason: { type: "string" },
    },
    required: ["category", "is_new", "confidence", "reason"],
  },
};

type Classification = {
  category: string;
  is_new: boolean;
  confidence: number;
  reason: string;
};

async function retry<T>(fn: () => Promise<T>, tries = 3, baseMs = 400): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      if (i < tries - 1) await new Promise((r) => setTimeout(r, baseMs * 2 ** i));
    }
  }
  throw lastErr;
}

async function classify(existing: string[], content: string): Promise<Classification> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL_HAIKU,
      max_tokens: 300,
      system: [{ type: "text", text: CLASSIFY_SYSTEM, cache_control: { type: "ephemeral" } }],
      tools: [CLASSIFY_TOOL],
      tool_choice: { type: "tool", name: "classify" }, // 구조화 출력 강제
      messages: [{ role: "user", content: `기존 카테고리: ${JSON.stringify(existing)}\n\n메모:\n${content}` }],
    }),
  });
  if (!res.ok) throw new Error(`anthropic ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const block = data.content?.find((b: { type: string }) => b.type === "tool_use");
  if (!block) throw new Error("anthropic: tool_use 블록 없음");
  return block.input as Classification;
}

async function embed(content: string): Promise<number[]> {
  const res = await fetch("https://api.cohere.com/v2/embed", {
    method: "POST",
    headers: { authorization: `Bearer ${COHERE_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL_EMBED,
      texts: [content],
      input_type: "search_document", // 저장 문서. recall도 문서↔문서 유사도라 동일 사용.
      embedding_types: ["float"],
    }),
  });
  if (!res.ok) throw new Error(`cohere ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const vec = data.embeddings?.float?.[0];
  if (!Array.isArray(vec) || vec.length !== EMBED_DIM) {
    throw new Error(`cohere: 임베딩 차원 이상 (${vec?.length})`);
  }
  return vec;
}

Deno.serve(async (req) => {
  // 1) 호출자 검증
  if (req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }

  let payload: { type?: string; record?: Record<string, unknown> };
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const rec = payload.record;
  if (!rec || typeof rec.id !== "string" || typeof rec.user_id !== "string") {
    return new Response("no record", { status: 400 });
  }
  // 2) 멱등 가드: 이미 임베딩 있으면 skip(자기 UPDATE 재트리거 방지, 재전송 방어)
  if (rec.embedding != null) return Response.json({ skipped: "already processed" });

  const memoId = rec.id as string;
  const userId = rec.user_id as string;
  const content = String(rec.content ?? "").trim();
  if (!content) return Response.json({ skipped: "empty content" });

  const supa = createClient(SUPABASE_URL, SERVICE_ROLE);

  try {
    // 3) 기존 카테고리
    const { data: cats, error: catErr } = await supa
      .from("categories").select("name").eq("user_id", userId);
    if (catErr) throw catErr;
    const existing = (cats ?? []).map((c) => c.name as string);

    // 4) 분류 + 5) 임베딩 (각각 재시도)
    const [cls, vec] = await Promise.all([
      retry(() => classify(existing, content)),
      retry(() => embed(content)),
    ]);

    // 6) 카테고리 id 확정 — race-safe upsert(중복 무시) 후 조회.
    //    ignoreDuplicates=true라 동시 신규제안 충돌해도 throw 없고 created_by_ai 클로버 안 됨.
    await supa.from("categories").upsert(
      { user_id: userId, name: cls.category, created_by_ai: cls.is_new },
      { onConflict: "user_id,name", ignoreDuplicates: true },
    );
    const { data: cat, error: findErr } = await supa
      .from("categories").select("id").eq("user_id", userId).eq("name", cls.category).single();
    if (findErr) throw findErr;

    // 7) 메모 갱신 (vector는 pgvector 텍스트 리터럴 '[...]'로)
    const { error: updErr } = await supa.from("memos").update({
      category_id: cat.id,
      embedding: `[${vec.join(",")}]`,
      embedding_model: MODEL_EMBED,
      embedding_dim: EMBED_DIM,
      embedding_version: EMBED_VERSION,
    }).eq("id", memoId);
    if (updErr) throw updErr;

    return Response.json({ ok: true, memo_id: memoId, category: cls.category, is_new: cls.is_new });
  } catch (e) {
    // 실패 시 memo는 embedding=null로 남음 → pg_cron 보정 스윕이 재처리.
    console.error(`process-memo 실패 memo=${memoId}:`, e);
    return new Response(`error: ${e instanceof Error ? e.message : e}`, { status: 500 });
  }
});
