import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import path from "node:path";
const root=process.env.LOCALAPPDATA||path.join(process.cwd(),"data");
const dir=process.env.JOBPILOT_DATA_DIR||path.join(root,"JobPilot");mkdirSync(dir,{recursive:true});
const globalDb=globalThis as unknown as {jobpilotDb?:DatabaseSync};
export const db=globalDb.jobpilotDb??new DatabaseSync(path.join(dir,"jobpilot.db"));
globalDb.jobpilotDb=db;
// Serialize concurrent opens (e.g. `next build` collects page data in parallel workers that each
// import this module and touch the DB) instead of failing fast with SQLITE_BUSY. Must be set before
// the WAL switch / DDL below, which take write locks.
db.exec(`PRAGMA busy_timeout=10000;`);
db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS resumes(id TEXT PRIMARY KEY,fileName TEXT,fileType TEXT,filePath TEXT,confirmed INTEGER DEFAULT 0,currentVersionId TEXT,createdAt TEXT,updatedAt TEXT);
CREATE TABLE IF NOT EXISTS resume_versions(id TEXT PRIMARY KEY,resumeId TEXT,parsedJson TEXT,missingJson TEXT,source TEXT,createdAt TEXT);
CREATE TABLE IF NOT EXISTS preferences(id TEXT PRIMARY KEY,rawText TEXT,city TEXT,jobType TEXT,industry TEXT,workMode TEXT,confirmed INTEGER,createdAt TEXT,updatedAt TEXT);
CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,name TEXT,url TEXT,sourceType TEXT,verified INTEGER);
CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,title TEXT,company TEXT,city TEXT,education TEXT,graduationYear INTEGER,workMode TEXT,industry TEXT,description TEXT,applicationType TEXT,applicationUrl TEXT,sourceId TEXT);
CREATE TABLE IF NOT EXISTS match_runs(id TEXT PRIMARY KEY,resumeVersionId TEXT,preferenceId TEXT,createdAt TEXT);
CREATE TABLE IF NOT EXISTS match_results(id TEXT PRIMARY KEY,runId TEXT,jobId TEXT,score INTEGER,eligible INTEGER,reasonsJson TEXT,mismatchJson TEXT,unknownJson TEXT,risksJson TEXT,selected INTEGER DEFAULT 0,UNIQUE(runId,jobId));
CREATE TABLE IF NOT EXISTS application_tasks(id TEXT PRIMARY KEY,jobId TEXT,resumeVersionId TEXT,idempotencyKey TEXT UNIQUE,status TEXT,adapter TEXT,errorCode TEXT,errorSummary TEXT,attempts INTEGER DEFAULT 0,createdAt TEXT,updatedAt TEXT);
CREATE TABLE IF NOT EXISTS application_history(id TEXT PRIMARY KEY,taskId TEXT,status TEXT,reason TEXT,createdAt TEXT);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT,updatedAt TEXT);`);
db.exec(`CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,passwordHash TEXT NOT NULL,passwordSalt TEXT NOT NULL,role TEXT NOT NULL DEFAULT 'user',createdAt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS user_settings(userId TEXT NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,updatedAt TEXT NOT NULL,PRIMARY KEY(userId,key));
CREATE TABLE IF NOT EXISTS user_secrets(userId TEXT NOT NULL,key TEXT NOT NULL,ciphertext TEXT NOT NULL,iv TEXT NOT NULL,tag TEXT NOT NULL,updatedAt TEXT NOT NULL,PRIMARY KEY(userId,key));
CREATE TABLE IF NOT EXISTS miniapp_accounts(openid TEXT PRIMARY KEY,unionid TEXT UNIQUE,emailUserId TEXT UNIQUE,userId TEXT NOT NULL,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL);`);
const jobColumns = db.prepare("PRAGMA table_info(jobs)").all() as Array<{name:string}>;
if (!jobColumns.some((column) => column.name === "applicationEmail")) db.exec("ALTER TABLE jobs ADD COLUMN applicationEmail TEXT");
function ensureColumn(table:string,column:string,definition:string){const columns=db.prepare(`PRAGMA table_info(${table})`).all() as Array<{name:string}>;if(!columns.some(item=>item.name===column))db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`)}
ensureColumn("resumes","userId","TEXT");
ensureColumn("preferences","userId","TEXT");
ensureColumn("match_runs","userId","TEXT");
ensureColumn("application_tasks","userId","TEXT");
ensureColumn("match_runs","searchWarning","TEXT");
ensureColumn("match_runs","consumedAt","TEXT");
ensureColumn("jobs","jobFingerprint","TEXT");
ensureColumn("jobs","sourceEvidenceJson","TEXT");
ensureColumn("jobs","sourceVerifiedAt","TEXT");
ensureColumn("jobs","catalogState","TEXT");
ensureColumn("jobs","catalogSourceKey","TEXT");
ensureColumn("jobs","catalogExternalId","TEXT");
ensureColumn("jobs","publishedAt","TEXT");
ensureColumn("jobs","expiresAt","TEXT");
ensureColumn("jobs","firstSeenAt","TEXT");
ensureColumn("jobs","lastSeenAt","TEXT");
ensureColumn("jobs","lastCheckedAt","TEXT");
ensureColumn("jobs","contentHash","TEXT");
ensureColumn("application_tasks","recipientEmail","TEXT");
ensureColumn("application_tasks","messageSubject","TEXT");
ensureColumn("application_tasks","messageBodyHash","TEXT");
ensureColumn("application_tasks","sourceEvidenceJson","TEXT");
ensureColumn("application_tasks","providerReference","TEXT");
ensureColumn("application_tasks","submittedAt","TEXT");
ensureColumn("application_tasks","manualRecipientEmail","TEXT");
ensureColumn("application_tasks","processingStartedAt","TEXT");
ensureColumn("match_runs","searchSource","TEXT");
ensureColumn("match_runs","catalogSnapshotAt","TEXT");
db.exec(`CREATE TABLE IF NOT EXISTS catalog_sources(
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  official INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  etag TEXT,
  lastModified TEXT,
  lastFetchedAt TEXT,
  lastSuccessAt TEXT,
  lastError TEXT,
  lastItemCount INTEGER NOT NULL DEFAULT 0,
  updatedAt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS catalog_refresh_runs(
  id TEXT PRIMARY KEY,
  startedAt TEXT NOT NULL,
  finishedAt TEXT,
  status TEXT NOT NULL,
  sourceCount INTEGER NOT NULL DEFAULT 0,
  fetchedCount INTEGER NOT NULL DEFAULT 0,
  acceptedCount INTEGER NOT NULL DEFAULT 0,
  rejectedCount INTEGER NOT NULL DEFAULT 0,
  expiredCount INTEGER NOT NULL DEFAULT 0,
  errorSummary TEXT
);
CREATE TABLE IF NOT EXISTS catalog_locks(
  name TEXT PRIMARY KEY,
  owner TEXT NOT NULL,
  leaseUntil TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);`);
db.exec("UPDATE jobs SET catalogState='legacy' WHERE catalogState IS NULL");
db.exec(`CREATE INDEX IF NOT EXISTS idx_match_runs_user_created ON match_runs(userId,createdAt DESC);
CREATE INDEX IF NOT EXISTS idx_match_results_run_score ON match_results(runId,score DESC);
CREATE INDEX IF NOT EXISTS idx_application_tasks_user_updated ON application_tasks(userId,updatedAt DESC);
CREATE INDEX IF NOT EXISTS idx_application_tasks_user_key ON application_tasks(userId,idempotencyKey);
CREATE INDEX IF NOT EXISTS idx_jobs_fingerprint ON jobs(jobFingerprint);
CREATE INDEX IF NOT EXISTS idx_jobs_catalog_freshness ON jobs(catalogState,lastSeenAt DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_catalog_identity ON jobs(catalogSourceKey,catalogExternalId);
CREATE INDEX IF NOT EXISTS idx_catalog_sources_enabled ON catalog_sources(enabled,lastSuccessAt DESC);
CREATE INDEX IF NOT EXISTS idx_catalog_refresh_runs_started ON catalog_refresh_runs(startedAt DESC);`);
const legacyOwnerSetting=db.prepare("SELECT value FROM settings WHERE key='smtpUser'").get() as {value?:string}|undefined;
const legacyOwnerEmail=process.env.JOBPILOT_OWNER_EMAIL||legacyOwnerSetting?.value;
const inviteHash=process.env.JOBPILOT_INVITE_PASSWORD_HASH;
if(legacyOwnerEmail&&inviteHash){const ownerEmail=legacyOwnerEmail.toLowerCase();const existing=db.prepare("SELECT id FROM users WHERE email=?").get(ownerEmail) as {id:string}|undefined;const ownerId=existing?.id||crypto.randomUUID();if(!existing)db.prepare("INSERT INTO users VALUES(?,?,?,?,?,?)").run(ownerId,ownerEmail,inviteHash,"legacy-sha256","owner",new Date().toISOString());for(const table of ["resumes","preferences","match_runs","application_tasks"])db.prepare(`UPDATE ${table} SET userId=? WHERE userId IS NULL`).run(ownerId);for(const key of ["smtpHost","smtpPort","smtpUser","smtpFrom"]){const row=db.prepare("SELECT value,updatedAt FROM settings WHERE key=?").get(key) as {value:string;updatedAt:string}|undefined;if(row)db.prepare("INSERT OR IGNORE INTO user_settings VALUES(?,?,?,?)").run(ownerId,key,row.value,row.updatedAt)}}
// A match run becomes historical once it has produced application tasks. Backfill older completed runs
// without deleting their results or application evidence.
db.exec(`UPDATE match_runs
SET consumedAt=(
  SELECT MAX(t.createdAt)
  FROM match_results r
  JOIN application_tasks t
    ON t.jobId=r.jobId
   AND t.userId=match_runs.userId
   AND t.resumeVersionId=match_runs.resumeVersionId
  WHERE r.runId=match_runs.id
    AND t.createdAt>=match_runs.createdAt
)
WHERE consumedAt IS NULL
  AND EXISTS(
    SELECT 1
    FROM match_results r
    JOIN application_tasks t
      ON t.jobId=r.jobId
     AND t.userId=match_runs.userId
     AND t.resumeVersionId=match_runs.resumeVersionId
    WHERE r.runId=match_runs.id
      AND t.createdAt>=match_runs.createdAt
  )`);
export const now=()=>new Date().toISOString();export const id=()=>crypto.randomUUID();
export function one<T=any>(sql:string,...args:any[]){return db.prepare(sql).get(...args) as T|undefined}
export function all<T=any>(sql:string,...args:any[]){return db.prepare(sql).all(...args) as T[]}
export function run(sql:string,...args:any[]){return db.prepare(sql).run(...args)}
export function transaction<T>(fn:()=>T){db.exec("BEGIN IMMEDIATE");try{const value=fn();db.exec("COMMIT");return value}catch(e){db.exec("ROLLBACK");throw e}}
