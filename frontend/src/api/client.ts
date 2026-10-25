import type { ApiErrorBody, Brief, Explanation, JournalEvent, Leaderboard, Message, Project, ProjectCreate, ProjectUpdate, Rubric, RubricState, Run, SubmissionDetail, SubmissionSummary } from './types'

const API_BASE = import.meta.env.VITE_API_URL ?? ''

export class ApiError extends Error {
  constructor(public status: number, public body: ApiErrorBody) { super(body.error.message); this.name = 'ApiError' }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, { credentials: 'include', ...init })
  if (!response.ok) {
    let body: ApiErrorBody
    try { body = await response.json() as ApiErrorBody } catch { body = { error: { code: 'internal', message: response.statusText, request_id: 'unknown' } } }
    throw new ApiError(response.status, body)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

const json = (body: unknown): RequestInit => ({ method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

export const api = {
  health: () => request<{ status: 'ok'; agents: 'up' | 'down' | 'unknown'; version?: string }>('/health'),
  login: (username: string, password: string) => request<void>('/api/v1/auth/login', json({ username, password })),
  logout: () => request<void>('/api/v1/auth/logout', { method: 'POST' }),
  me: () => request<{ username: string }>('/api/v1/auth/me'),
  listProjects: (includeArchived = false) => request<{ items: Project[] }>(`/api/v1/projects?include_archived=${includeArchived}`),
  createProject: (body: ProjectCreate) => request<Project>('/api/v1/projects', { ...json(body), method: 'POST' }),
  getProject: (id: string) => request<Project>(`/api/v1/projects/${id}`),
  updateProject: (id: string, body: ProjectUpdate) => request<Project>(`/api/v1/projects/${id}`, { ...json(body), method: 'PATCH' }),
  listMessages: (id: string, after?: string, limit = 50) => request<{ items: Message[]; next_cursor: string | null }>(`/api/v1/projects/${id}/messages${cursor(after, limit)}`),
  postMessage: (id: string, text: string) => request<Message>(`/api/v1/projects/${id}/messages`, json({ text })),
  listBriefs: (id: string) => request<{ items: Brief[] }>(`/api/v1/projects/${id}/briefs`),
  uploadBriefs: (id: string, form: FormData) => request<{ items: Brief[] }>(`/api/v1/projects/${id}/briefs`, { method: 'POST', body: form }),
  getRubric: (id: string) => request<RubricState>(`/api/v1/projects/${id}/rubric`),
  saveRubric: (id: string, body: { criteria: unknown[]; expected_version: number }) => request<Rubric>(`/api/v1/projects/${id}/rubric`, { ...json(body), method: 'PUT' }),
  requestRubricDraft: (id: string) => request<void>(`/api/v1/projects/${id}/rubric/draft`, { method: 'POST' }),
  confirmRubric: (id: string, version: number) => request<Rubric>(`/api/v1/projects/${id}/rubric/confirm`, json({ version })),
  getUxMetrics: (id: string) => request<{ metrics: { name: string; how_to_measure: string; good_looks_like: string }[] }>(`/api/v1/projects/${id}/ux-metrics`),
  listSubmissions: (id: string) => request<{ items: SubmissionSummary[] }>(`/api/v1/projects/${id}/submissions`),
  createSubmission: (id: string, form: FormData) => request<SubmissionSummary>(`/api/v1/projects/${id}/submissions`, { method: 'POST', body: form }),
  createSubmissionsBatch: (id: string, form: FormData) => request<{ items: SubmissionSummary[]; rejected: { row: string; reason: string }[] }>(`/api/v1/projects/${id}/submissions:batch`, { method: 'POST', body: form }),
  getSubmission: (id: string) => request<SubmissionDetail>(`/api/v1/submissions/${id}`),
  getExplanation: (submissionId: string, criterionId: string) => request<Explanation>(`/api/v1/submissions/${submissionId}/criteria/${criterionId}`),
  overrideScore: (submissionId: string, criterionId: string, body: { score: number; reason: string; expected_version: number }) => request<Explanation>(`/api/v1/submissions/${submissionId}/criteria/${criterionId}/override`, { ...json(body), method: 'PUT' }),
  listRuns: (id: string) => request<{ items: Run[] }>(`/api/v1/projects/${id}/runs`),
  startRun: (id: string, body: Record<string, unknown> = {}) => request<Run>(`/api/v1/projects/${id}/runs`, json(body)),
  getRun: (id: string) => request<Run>(`/api/v1/runs/${id}`),
  getJournal: (runId: string, params: { submission_id?: string; role?: string; after?: string; limit?: number } = {}) => request<{ items: JournalEvent[]; next_cursor: string | null }>(`/api/v1/runs/${runId}/journal${query(params)}`),
  getLeaderboard: (id: string, params: { sort?: string; order?: 'asc' | 'desc'; flag?: string } = {}) => request<Leaderboard>(`/api/v1/projects/${id}/leaderboard${query(params)}`),
  exportCsv: (id: string) => request<string>(`/api/v1/projects/${id}/export.csv`),
}

export function projectEventsUrl(projectId: string) { return `${API_BASE}/api/v1/projects/${projectId}/events` }
function cursor(after: string | undefined, limit: number) { return query({ after, limit }) }
function query(params: Record<string, unknown>) { const search = new URLSearchParams(); Object.entries(params).forEach(([key, value]) => value != null && search.set(key, String(value))); const value = search.toString(); return value ? `?${value}` : '' }
