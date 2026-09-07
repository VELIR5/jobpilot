const SHA_PATTERN = /^[0-9a-f]{40}$/i;

export async function GET() {
  const configuredSha = process.env.JOBPILOT_RELEASE_SHA?.trim() || "";
  const releasedAt = process.env.JOBPILOT_RELEASED_AT?.trim() || null;

  return Response.json(
    {
      status: "ok",
      releaseSha: SHA_PATTERN.test(configuredSha) ? configuredSha.toLowerCase() : "unknown",
      releasedAt,
    },
    {
      headers: {
        "Cache-Control": "no-store, max-age=0",
      },
    },
  );
}
