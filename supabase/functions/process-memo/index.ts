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

// 분류 규칙 = 안정적이라 캐싱 대상. 폴더 트리는 바뀌므로 user 메시지에.
const CLASSIFY_SYSTEM = `너는 개인 메모 앱의 폴더 분류기다.

사용자는 자기만의 폴더 트리(최대 3뎁스)를 직접 설계했다. 각 폴더엔 제목(title)과
설명(description)이 있고, 이미 들어있는 예시 메모가 붙어 있을 수 있다.

너의 역할: 새 메모를 이 트리 안에서 **가장 알맞은 폴더 하나로 이동**시키는 것뿐이다.

규칙:
- **폴더를 새로 만들지 마라.** 아래에 주어진 folder_id 중 하나만 고를 수 있다.
- 판단 힌트: 폴더의 title + description + 그 폴더에 이미 든 예시 메모들의 내용.
- 메모는 아무 뎁스에나 놓일 수 있다. 상위 폴더가 더 알맞으면 상위 폴더를 골라도 된다.
- 어느 폴더에도 합리적으로 맞지 않으면 **folder_id를 생략하라**(미분류). '약하게만'
  걸치는 억지 분류는 하지 마라(예: 마케팅 메모를 "개발"에 넣지 마라).
- confidence는 '고른 폴더가 맞다'는 확신도다(0~1). **0.4 미만이면 억지로 넣지 말고
  folder_id를 생략하라.** 0.4 이상일 때만 그 폴더를 고른다.`;

// folder_id는 optional string(미분류면 생략). union type(["string","null"])는 API 호환성
// 이슈 소지가 있어, "없으면 생략"으로 처리 → 아래에서 absent/미존재 모두 null 취급.
const CLASSIFY_TOOL = {
  name: "classify",
  description: "메모를 폴더 트리 안의 폴더로 분류한다. 맞는 폴더가 없으면 folder_id를 생략한다(미분류).",
  input_schema: {
    type: "object",
    properties: {
      folder_id: {
        type: "string",
        description: "고른 폴더의 id(트리에 있는 것만). 맞는 폴더가 없으면 이 필드를 생략(미분류).",
      },
      confidence: { type: "number", description: "고른 폴더가 맞다는 확신 0~1" },
      reason: { type: "string" },
    },
    required: ["confidence", "reason"],
  },
};

type Classification = {
  folder_id?: string | null;
  confidence: number;
  reason: string;
};

type FolderRow = { id: string; parent_id: string | null; title: string; description: string | null };

const SAMPLES_PER_FOLDER = 5;   // 폴더당 예시 메모 수(토큰 관리)
const SAMPLE_CHARS = 120;       // 예시 메모 앞부분만
const SAMPLE_FETCH_LIMIT = 300; // 샘플 원본으로 끌어올 최대 메모 행

// 폴더 트리를 들여쓰기 텍스트로 직렬화. 각 폴더 = id + title + description + 예시메모.
function renderTree(folders: FolderRow[], samples: Map<string, string[]>): string {
  const byParent = new Map<string | null, FolderRow[]>();
  for (const f of folders) {
    const key = f.parent_id ?? null;
    (byParent.get(key) ?? byParent.set(key, []).get(key)!).push(f);
  }
  const lines: string[] = [];
  const walk = (parent: string | null, depth: number) => {
    for (const f of byParent.get(parent) ?? []) {
      const pad = "  ".repeat(depth);
      lines.push(`${pad}- [${f.id}] ${f.title}${f.description ? ` — ${f.description}` : ""}`);
      for (const s of samples.get(f.id) ?? []) {
        lines.push(`${pad}    · 예시메모: ${s}`);
      }
      walk(f.id, depth + 1);
    }
  };
  walk(null, 0);
  return lines.join("\n");
}

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

async function classify(treeText: string, content: string): Promise<Classification> {
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
      messages: [{ role: "user", content: `폴더 트리:\n${treeText}\n\n분류할 메모:\n${content}` }],
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
    // 3) 사용자 폴더 트리 조회. AI는 이 안에서만 고른다(새 폴더 생성 없음).
    const { data: folderData, error: folderErr } = await supa
      .from("folders").select("id,parent_id,title,description").eq("user_id", userId);
    if (folderErr) throw folderErr;
    const folders = (folderData ?? []) as FolderRow[];
    const folderIds = new Set(folders.map((f) => f.id));

    // 3b) 폴더별 예시 메모(분류 힌트). 최신순으로 한도까지 끌어와 폴더당 상위 N개만 사용.
    const samples = new Map<string, string[]>();
    if (folders.length > 0) {
      const { data: sampleRows, error: sampleErr } = await supa
        .from("memos").select("folder_id,content")
        .eq("user_id", userId)
        .not("folder_id", "is", null)
        .is("deleted_at", null)
        .neq("id", memoId)
        .order("created_at", { ascending: false })
        .limit(SAMPLE_FETCH_LIMIT);
      if (sampleErr) throw sampleErr;
      for (const r of (sampleRows ?? []) as { folder_id: string; content: string }[]) {
        const arr = samples.get(r.folder_id) ?? [];
        if (arr.length < SAMPLES_PER_FOLDER) {
          arr.push(String(r.content ?? "").replace(/\s+/g, " ").trim().slice(0, SAMPLE_CHARS));
          samples.set(r.folder_id, arr);
        }
      }
    }

    // 4) 분류 + 5) 임베딩. 빈 트리면 분류 LLM 스킵(무조건 미분류) → 비용 절약.
    const [cls, vec] = await Promise.all([
      folders.length === 0
        ? Promise.resolve<Classification>({ folder_id: null, confidence: 0, reason: "폴더 없음" })
        : retry(() => classify(renderTree(folders, samples), content)),
      retry(() => embed(content)),
    ]);

    // 6) 환각 방어: 모델이 트리에 없는 folder_id를 반환하면 미분류(null)로 강등.
    const folderId = cls.folder_id && folderIds.has(cls.folder_id) ? cls.folder_id : null;

    // 7) 메모 갱신 (vector는 pgvector 텍스트 리터럴 '[...]'로)
    const { error: updErr } = await supa.from("memos").update({
      folder_id: folderId,
      embedding: `[${vec.join(",")}]`,
      embedding_model: MODEL_EMBED,
      embedding_dim: EMBED_DIM,
      embedding_version: EMBED_VERSION,
    }).eq("id", memoId);
    if (updErr) throw updErr;

    return Response.json({ ok: true, memo_id: memoId, folder_id: folderId });
  } catch (e) {
    // 실패 시 memo는 embedding=null로 남음 → pg_cron 보정 스윕이 재처리.
    console.error(`process-memo 실패 memo=${memoId}:`, e);
    return new Response(`error: ${e instanceof Error ? e.message : e}`, { status: 500 });
  }
});
