import { describe, expect, it } from "vitest";
import { NextRequest } from "next/server";
import { proxy } from "./proxy";

function request(path: string, options: { bearer?: string; cookies?: Record<string, string> } = {}) {
  const headers = new Headers();
  if (options.bearer) headers.set("authorization", options.bearer);
  if (options.cookies) {
    headers.set("cookie", Object.entries(options.cookies).map(([key, value]) => `${key}=${value}`).join("; "));
  }
  return new NextRequest(`http://localhost${path}`, { headers });
}

describe("cross-client middleware", () => {
  it("allows the release health check without browser cookies", () => {
    const response = proxy(request("/api/health"));
    expect(response.status).toBe(200);
  });

  it("allows the mini-program session exchange without browser cookies", () => {
    const response = proxy(request("/api/miniapp/session"));
    expect(response.status).toBe(200);
  });

  it("allows bearer API requests through to route-level signature verification", () => {
    const response = proxy(request("/api/state", { bearer: "Bearer user.signature" }));
    expect(response.status).toBe(200);
  });

  it("still rejects uncredentialed protected API requests", async () => {
    const response = proxy(request("/api/state"));
    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toMatchObject({ error: "需要访问密码" });
  });

  it("keeps the existing browser cookie path unchanged", () => {
    const response = proxy(request("/api/state", { cookies: { jobpilot_gate: "gate", jobpilot_session: "user.sig" } }));
    expect(response.status).toBe(200);
  });
});
