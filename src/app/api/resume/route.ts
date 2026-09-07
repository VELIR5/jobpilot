import { extractResumeText, RESUME_TYPES, structureResume } from "@/application/resume-parser";
import { id, now, run, transaction } from "@/infrastructure/db";
import { mkdir, writeFile, unlink } from "node:fs/promises";
import path from "node:path";
import { requireUser } from "@/infrastructure/auth";

export async function POST(req: Request) {
  const user=await requireUser();
  const form = await req.formData();
  const file = form.get("file");
  if (!(file instanceof File)) return Response.json({ error: "请选择简历文件" }, { status: 400 });
  if (!RESUME_TYPES.includes(file.type as typeof RESUME_TYPES[number]) || file.size > 5 * 1024 * 1024) {
    return Response.json({ error: "仅支持 5MB 内的 PDF、DOCX 或 TXT" }, { status: 400 });
  }
  const bytes = Buffer.from(await file.arrayBuffer());
  let text = "";
  try {
    text = await extractResumeText(bytes, file.type);
  } catch (error) {
    console.error("resume_extract_failed", error instanceof Error ? error.message : "unknown error");
    return Response.json({ error: "无法读取这份简历，请确认文件未加密或损坏" }, { status: 422 });
  }
  if (text.trim().length < 20) return Response.json({ error: "没有提取到足够文字；扫描版 PDF 请先进行 OCR" }, { status: 422 });

  const directory = process.env.JOBPILOT_UPLOAD_DIR || path.join(process.cwd(), "data", "uploads");
  await mkdir(directory, { recursive: true });
  const resumeId = id();
  const filePath = path.join(/* turbopackIgnore: true */ directory, resumeId);
  await writeFile(filePath, bytes);
  try {
    const parsed = structureResume(text);
    const missing = Object.entries(parsed).filter(([, value]) => !value || (Array.isArray(value) && !value.length)).map(([key]) => key);
    const version = { id: id(), resumeId, parsedJson: JSON.stringify(parsed), missingJson: JSON.stringify(missing), source: "local_parser", createdAt: now() };
    transaction(() => {
      run("INSERT INTO resumes(id,fileName,fileType,filePath,confirmed,currentVersionId,createdAt,updatedAt,userId) VALUES(?,?,?,?,?,?,?,?,?)", resumeId, file.name, file.type, filePath, 0, null, now(), now(),user.id);
      run("INSERT INTO resume_versions VALUES(?,?,?,?,?,?)", version.id, version.resumeId, version.parsedJson, version.missingJson, version.source, version.createdAt);
    });
    return Response.json({ id: resumeId, versions: [version], extractedCharacters: text.length });
  } catch (error) {
    await unlink(filePath).catch(() => undefined);
    return Response.json({ error: "解析结果保存失败，请重试" }, { status: 500 });
  }
}
