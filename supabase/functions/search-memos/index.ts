// search-memos — 시맨틱 메모 검색
// 흐름: 앱(인증) → 쿼리 텍스트 → Cohere 임베딩(search_query) → match_memos(RLS) → 유사도 top-k
//
// 보안:
// - verify_jwt=true. 유저 Authorization 헤더로 유저 스코프 클라이언트 생성 →
//   match_memos가 auth.uid()로 RLS 스코프(본인 메모만).
// - COHERE_API_KEY는 Edge secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MODEL_EMBED = "embed-multilingual-v3.0";
const EMBED_DIM = 1024;
const SIMILARITY_FLOOR = 0.3; // 무관 쿼리가 쓰레기 결과 내지 않게 하한(실데이터 튜닝)

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const COHERE_KEY = Deno.env.get("COHERE_API_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

async function embedQuery(text: string): Promise<number[]> {
  const res = await fetch("https://api.cohere.com/v2/embed", {
    method: "POST",
    headers: { authorization: `Bearer ${COHERE_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL_EMBED,
      texts: [text],
      input_type: "search_query", // 쿼리측(저장 문서는 search_document)
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
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const auth = req.headers.get("Authorization");
  if (!auth) return new Response("unauthorized", { status: 401, headers: cors });

  let body: { query?: string; count?: number };
  try {
    body = await req.json();
  } catch {
    return new Response("bad request", { status: 400, headers: cors });
  }
  const query = String(body.query ?? "").trim();
  const count = Math.min(Math.max(body.count ?? 20, 1), 50);
  if (!query) return Response.json({ results: [] }, { headers: cors });

  // 유저 스코프 클라이언트 — RPC가 auth.uid()로 RLS 스코프
  const supa = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: auth } },
  });

  try {
    const vec = await embedQuery(query);
    const { data, error } = await supa.rpc("match_memos", {
      query_embedding: `[${vec.join(",")}]`,
      match_count: count,
    });
    if (error) throw error;
    const results = ((data ?? []) as { id: string; content: string; category_id: string | null; similarity: number }[])
      .filter((r) => r.similarity >= SIMILARITY_FLOOR);
    return Response.json({ results }, { headers: cors });
  } catch (e) {
    console.error("search-memos 실패:", e);
    return new Response(`error: ${e instanceof Error ? e.message : e}`, { status: 500, headers: cors });
  }
});
