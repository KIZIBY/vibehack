export type ProjectType = 'product_hackathon' | 'ml_hackathon' | 'homework' | 'other'
export type ProjectStatus = 'setup' | 'intake' | 'evaluating' | 'results' | 'archived'
export type Role = 'rubric' | 'sorter' | 'code' | 'business' | 'design' | 'critic-uniqueness' | 'critic-honesty'
export type ScoringRole = Exclude<Role, 'rubric' | 'sorter'> | 'human'
export type FlagType = 'plagiarism' | 'pre_start_project' | 'claim_mismatch' | 'prompt_injection' | 'incomplete_materials' | 'agent_failure' | 'secret_exposed'
export type MaterialType = 'repository' | 'host' | 'presentation' | 'screencast' | 'archive' | 'code_file' | 'document' | 'image' | 'metrics_row' | 'other'

export interface ApiErrorBody { error: { code: string; message: string; request_id: string; details?: Record<string, unknown> } }
export interface Project { id: string; name: string; type: ProjectType; status: ProjectStatus; starts_on: string | null; ends_on: string | null; agents: ScoringRole[]; required_materials: MaterialType[]; rubric_confirmed_version: number | null; retention_days: number; purge_at: string | null; cost_usd: number | null; version: number; created_at: string; updated_at: string }
export interface Message { id: string; author: 'organizer' | 'agent' | 'system'; kind: 'text' | 'brief_extracted' | 'rubric_drafted' | 'inventory_ready' | 'run_progress' | 'run_completed' | 'warning'; text: string; attachments?: { name: string; material_id?: string }[]; created_at: string }
export interface Brief { id: string; name: string; source?: 'upload' | 'url' | 'chat'; status: 'processing' | 'extracted' | 'failed' | 'deleted'; reason?: string }
export interface Anchor { score: number; meaning: string }
export interface CriterionInput { id?: string; name: string; description?: string; weight: number; max_score: number; agent: ScoringRole; anchors?: Anchor[] }
export interface Criterion extends CriterionInput { id: string; source_ref?: string | null }
export interface Rubric { version: number; status: 'draft' | 'confirmed' | 'superseded'; weights_were_missing?: boolean; criteria: Criterion[]; confirmed_at?: string | null; created_at: string }
export interface RubricState { current: Rubric | null; versions: { version: number; status: Rubric['status']; created_at: string }[] }
export interface FlagCount { type: FlagType; count: number }
export interface SubmissionSummary { id: string; team_name: string; intake_status: 'pending' | 'running' | 'ready' | 'failed'; completeness?: 'complete' | 'incomplete' | 'unknown'; missing?: MaterialType[]; evaluation_status: 'not_started' | 'running' | 'done' | 'partial' | 'failed'; flags: FlagCount[] }
export interface MaterialStatus { material_id: string; type: MaterialType; name?: string; status: 'available' | 'partial' | 'unavailable' | 'deleted'; reason?: string }
export interface Evidence { kind: 'file' | 'slide' | 'video' | 'screenshot' | 'url' | 'claim' | 'commit' | 'search'; ref: string; quote?: string; available?: boolean }
export interface Flag { type: FlagType; criterion_id?: string; confidence: number; note: string; evidence: Evidence[]; related_submission_id?: string; related_url?: string }
export interface SubmissionDetail { id: string; team_name: string; materials: MaterialStatus[]; total?: number | null; complete?: boolean; criteria: { criterion_id: string; name: string; status: 'scored' | 'no_data' | 'human_pending'; score?: number | null; max_score: number; overridden?: boolean }[]; flags: Flag[]; cost_usd?: number | null; latest_run_id?: string | null }
export interface Explanation { criterion_id: string; criterion_name: string; team_name?: string; status: 'scored' | 'no_data' | 'human_pending'; score?: number | null; max_score: number; agent_score?: number | null; agent?: ScoringRole; justification?: string; no_data_reason?: string; confidence?: number; evidence: Evidence[]; flags?: Flag[]; override?: { score: number; reason: string; at: string } | null; run_id: string; version: number }
export interface Run { id: string; project_id: string; status: 'queued' | 'running' | 'completed' | 'partial' | 'failed'; rubric_version: number; tasks: { submission_id: string | null; role: Role; state: 'queued' | 'running' | 'done' | 'failed' | 'no_data'; attempt?: number; reason?: string }[]; tokens_in?: number | null; tokens_out?: number | null; cost_usd?: number | null; created_at: string; finished_at?: string | null }
export interface Leaderboard { project_id: string; rubric_version: number | null; generated_at: string; stale_criteria?: string[]; criteria: { id: string; name: string; weight: number; max_score: number; agent: ScoringRole }[]; rows: { submission_id: string; team_name: string; rank: number | null; total: number | null; complete: boolean; cells: Record<string, { status: 'scored' | 'no_data' | 'human_pending' | 'not_evaluated'; score: number | null; max_score: number; overridden: boolean; stale: boolean }>; flags: FlagCount[] }[]; cost_usd?: number | null }
export interface JournalEvent { id: string; seq: number; at: string; event: string; run_id?: string; submission_id?: string; role?: Role; payload: Record<string, unknown> }

export interface ProjectCreate { name: string; type: ProjectType; starts_on?: string | null; ends_on?: string | null }
export interface ProjectUpdate { expected_version: number; name?: string; starts_on?: string | null; ends_on?: string | null; agents?: ScoringRole[]; required_materials?: MaterialType[]; archived?: boolean }
