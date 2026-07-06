// delete-account — 로그인 사용자가 자기 계정을 영구 삭제.
// verify_jwt=true(기본)라 인증된 호출만. JWT에서 사용자 확인 후 service_role로 삭제.
// auth.users 삭제 → memos/categories는 FK on delete cascade로 자동 삭제.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("unauthorized", { status: 401 });

  // 호출자 JWT로 본인 확인
  const asUser = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userErr } = await asUser.auth.getUser();
  if (userErr || !user) return new Response("unauthorized", { status: 401 });

  // service_role로 사용자 삭제(데이터는 cascade)
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) return new Response(`delete failed: ${error.message}`, { status: 500 });

  return Response.json({ ok: true });
});
