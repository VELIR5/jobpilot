import { afterEach, describe, expect, it } from "vitest";

import { GET } from "./route";

const originalSha = process.env.JOBPILOT_RELEASE_SHA;
const originalReleasedAt = process.env.JOBPILOT_RELEASED_AT;

afterEach(() => {
  if (originalSha === undefined) delete process.env.JOBPILOT_RELEASE_SHA;
  else process.env.JOBPILOT_RELEASE_SHA = originalSha;
  if (originalReleasedAt === undefined) delete process.env.JOBPILOT_RELEASED_AT;
  else process.env.JOBPILOT_RELEASED_AT = originalReleasedAt;
});

describe("deployment health endpoint", () => {
  it("reports the deployed commit without allowing caches", async () => {
    process.env.JOBPILOT_RELEASE_SHA = "4ABD3A6128D64F1717786C1FC8F679038DCE89EB";
    process.env.JOBPILOT_RELEASED_AT = "2026-09-07T08:00:00.000Z";

    const response = await GET();

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store, max-age=0");
    await expect(response.json()).resolves.toEqual({
      status: "ok",
      releaseSha: "4abd3a6128d64f1717786c1fc8f679038dce89eb",
      releasedAt: "2026-09-07T08:00:00.000Z",
    });
  });

  it("does not echo malformed release metadata", async () => {
    process.env.JOBPILOT_RELEASE_SHA = "not-a-commit";
    delete process.env.JOBPILOT_RELEASED_AT;

    const response = await GET();

    await expect(response.json()).resolves.toEqual({
      status: "ok",
      releaseSha: "unknown",
      releasedAt: null,
    });
  });
});
