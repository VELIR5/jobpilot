import {NextRequest,NextResponse} from "next/server";

// Two layers: (1) shared site-access gate cookie, (2) per-user identity session. Both are presence-checked
// here (cheap, edge-safe); the real verification happens in the route/page (signed values / currentUser).
export function proxy(request:NextRequest){
  const {pathname}=request.nextUrl;
  const isApi=pathname.startsWith("/api/");
  // Mini-program clients cannot carry the browser-only gate/session cookies. The session exchange
  // endpoint is public by design, while other bearer API requests are only allowed past this cheap
  // edge presence check; currentUser() still verifies the HMAC before any protected route runs.
  const isHealthCheck=pathname==="/api/health";
  const isMiniappSession=pathname==="/api/miniapp/session";
  const hasBearer=isApi&&/^Bearer\s+\S+$/i.test(request.headers.get("authorization")||"");
  if(isHealthCheck||isMiniappSession||hasBearer)return NextResponse.next();
  // Layer 1 — site access gate.
  if(!request.cookies.has("jobpilot_gate")){
    if(isApi)return Response.json({error:"需要访问密码"},{status:401});
    const url=request.nextUrl.clone();url.pathname="/gate";url.searchParams.set("next",pathname);return NextResponse.redirect(url);
  }
  // Gated through. Sign-in surfaces don't require a session.
  if(pathname==="/invite"||pathname==="/api/invite"||pathname.startsWith("/api/oauth/"))return NextResponse.next();
  // Layer 2 — identity.
  if(!request.cookies.has("jobpilot_session")){
    if(isApi)return Response.json({error:"请先登录"},{status:401});
    const url=request.nextUrl.clone();url.pathname="/invite";url.searchParams.set("next",pathname);return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config={matcher:["/((?!gate|api/gate|_next/static|_next/image|favicon.ico).*)"]};
