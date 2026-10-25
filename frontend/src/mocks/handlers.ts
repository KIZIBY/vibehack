import { http, HttpResponse } from 'msw'
import type { Project, Rubric, SubmissionSummary } from '../api/types'

const now = '2026-10-25T10:00:00Z'
const projects: Project[] = [
  { id: 'p-spring', name: 'Весенний хакатон', type: 'product_hackathon', status: 'setup', starts_on: '2026-11-01', ends_on: '2026-11-03', agents: ['code', 'business', 'design'], required_materials: ['repository', 'presentation'], rubric_confirmed_version: null, retention_days: 7, purge_at: null, cost_usd: null, version: 2, created_at: now, updated_at: now },
  { id: 'p-good', name: 'AI for Good', type: 'product_hackathon', status: 'results', starts_on: '2026-09-12', ends_on: '2026-09-14', agents: ['code', 'business', 'design', 'critic-honesty'], required_materials: ['repository', 'host', 'presentation'], rubric_confirmed_version: 3, retention_days: 7, purge_at: null, cost_usd: 4.82, version: 4, created_at: '2026-08-01T10:00:00Z', updated_at: now },
]
const criteria = [
  { id: 'c-impact', name: 'Польза и влияние', description: 'Насколько решение решает проблему пользователя.', weight: 0.4, max_score: 10, agent: 'business' as const, anchors: [{ score: 10, meaning: 'Сильный измеримый эффект' }] },
  { id: 'c-code', name: 'Качество реализации', description: 'Архитектура, тесты и безопасность.', weight: 0.35, max_score: 10, agent: 'code' as const, anchors: [{ score: 10, meaning: 'Продакшен-готовое решение' }] },
  { id: 'c-design', name: 'Опыт пользователя', description: 'Понятность и удобство интерфейса.', weight: 0.25, max_score: 10, agent: 'design' as const, anchors: [{ score: 10, meaning: 'Интерфейс не требует объяснений' }] },
]
const rubric: Rubric = { version: 3, status: 'draft', weights_were_missing: false, criteria, confirmed_at: null, created_at: now }
const submissions: SubmissionSummary[] = [
  { id: 's-aurora', team_name: 'Аврора', intake_status: 'ready', completeness: 'complete', missing: [], evaluation_status: 'done', flags: [] },
  { id: 's-north', team_name: 'Север', intake_status: 'ready', completeness: 'incomplete', missing: ['presentation'], evaluation_status: 'partial', flags: [{ type: 'incomplete_materials', count: 1 }] },
  { id: 's-orbit', team_name: 'Орбита', intake_status: 'ready', completeness: 'complete', missing: [], evaluation_status: 'not_started', flags: [] },
]

function errorResponse(request: Request) {
  const queryError = new URL(request.url).searchParams.get('mock_error')
  if (!queryError) return null
  const status = Number(queryError) as 401 | 409 | 413 | 429
  const details = { 401: ['unauthorized', 'Войдите в аккаунт'], 409: ['version_conflict', 'Данные были изменены другим пользователем'], 413: ['too_large', 'Файл превышает допустимый размер'], 429: ['rate_limited', 'Слишком много запросов'] }[status]
  return HttpResponse.json({ error: { code: details?.[0] ?? 'invalid', message: details?.[1] ?? 'Некорректный запрос', request_id: 'mock-request-001' } }, { status: status || 422 })
}
function json<T>(request: Request, body: T, status = 200) { return errorResponse(request) ?? HttpResponse.json(body as Parameters<typeof HttpResponse.json>[0], { status }) }
function project(id: string) { return projects.find((item) => item.id === id) ?? projects[0] }
function briefItems() { return [{ id: 'b-rules', name: 'Положение.pdf', source: 'upload', status: 'extracted' as const }, { id: 'b-brief', name: 'Сайт проекта', source: 'url' as const, status: 'processing' as const }] }
function submissionDetail(id: string) { return { id, team_name: submissions.find((item) => item.id === id)?.team_name ?? 'Команда', materials: [{ material_id: 'm-repo', type: 'repository' as const, name: 'repository', status: 'available' as const }, { material_id: 'm-presentation', type: 'presentation' as const, name: 'presentation.pdf', status: id === 's-north' ? 'unavailable' as const : 'available' as const, reason: id === 's-north' ? 'Ссылка возвращает 404' : undefined }], total: id === 's-north' ? null : 82.5, complete: id !== 's-north', criteria: criteria.map((item, index) => ({ criterion_id: item.id, name: item.name, status: id === 's-north' && index === 2 ? 'no_data' as const : 'scored' as const, score: id === 's-north' && index === 2 ? null : 7 + index, max_score: 10, overridden: false })), flags: id === 's-north' ? [{ type: 'incomplete_materials' as const, confidence: 1, note: 'Презентация недоступна', evidence: [] }] : [], cost_usd: id === 's-north' ? null : 0.82, latest_run_id: 'run-demo' }
}

export const handlers = [
  http.get('/health', ({ request }) => json(request, { status: 'ok', agents: 'up', version: '0.1.0' })),
  http.post('/api/v1/auth/login', async ({ request }) => {
    const body = await request.json() as { username?: string }
    if (body.username === 'rate-limit') return HttpResponse.json({ error: { code: 'rate_limited', message: 'Слишком много попыток', request_id: 'mock-login-429' } }, { status: 429 })
    if (body.username === 'wrong') return HttpResponse.json({ error: { code: 'unauthorized', message: 'Неверный логин или пароль', request_id: 'mock-login-401' } }, { status: 401 })
    return json(request, undefined, 204)
  }),
  http.post('/api/v1/auth/logout', ({ request }) => json(request, undefined, 204)),
  http.get('/api/v1/auth/me', ({ request }) => json(request, { username: 'judge-demo' })),
  http.get('/api/v1/projects', ({ request }) => json(request, { items: projects })),
  http.post('/api/v1/projects', async ({ request }) => { const body = await request.json() as { name: string; type: Project['type'] }; const item = { ...projects[0], id: `p-${Date.now()}`, name: body.name, type: body.type, status: 'setup' as const }; return json(request, item, 201) }),
  http.get('/api/v1/projects/:projectId', ({ request, params }) => json(request, project(String(params.projectId)))),
  http.patch('/api/v1/projects/:projectId', async ({ request, params }) => { const item = project(String(params.projectId)); const body = await request.json() as { name?: string }; return json(request, { ...item, ...body, version: item.version + 1, updated_at: now }) }),
  http.get('/api/v1/projects/:projectId/messages', ({ request }) => json(request, { items: [{ id: 'msg-1', author: 'system', kind: 'text', text: 'Добавьте вводные материалы, чтобы собрать рубрику.', created_at: now }, { id: 'msg-2', author: 'organizer', kind: 'text', text: 'Ждём решения команд до пятницы.', created_at: now }], next_cursor: null })),
  http.post('/api/v1/projects/:projectId/messages', async ({ request }) => json(request, { id: 'msg-new', author: 'organizer', kind: 'text', text: (await request.json() as { text: string }).text, created_at: now }, 201)),
  http.get('/api/v1/projects/:projectId/briefs', ({ request }) => json(request, { items: briefItems() })),
  http.post('/api/v1/projects/:projectId/briefs', ({ request }) => json(request, { items: briefItems() }, 201)),
  http.get('/api/v1/projects/:projectId/rubric', ({ request }) => json(request, { current: rubric, versions: [{ version: 3, status: 'draft', created_at: now }, { version: 2, status: 'superseded', created_at: '2026-10-20T10:00:00Z' }] })),
  http.put('/api/v1/projects/:projectId/rubric', ({ request }) => json(request, { ...rubric, version: rubric.version + 1 })),
  http.post('/api/v1/projects/:projectId/rubric/draft', ({ request }) => json(request, undefined, 202)),
  http.post('/api/v1/projects/:projectId/rubric/confirm', ({ request }) => json(request, { ...rubric, status: 'confirmed' as const, confirmed_at: now })),
  http.get('/api/v1/projects/:projectId/ux-metrics', ({ request }) => json(request, { metrics: [{ name: 'Время до первого действия', how_to_measure: 'Скринкаст прохождения', good_looks_like: 'Меньше 30 секунд' }] })),
  http.get('/api/v1/projects/:projectId/submissions', ({ request }) => json(request, { items: submissions })),
  http.post('/api/v1/projects/:projectId/submissions', ({ request }) => json(request, { ...submissions[2], id: `s-${Date.now()}`, intake_status: 'pending' as const }, 201)),
  http.post('/api/v1/projects/:projectId/submissions:batch', ({ request }) => json(request, { items: [submissions[2]], rejected: [{ row: 'Команда 4', reason: 'Не указан репозиторий' }] }, 201)),
  http.get('/api/v1/submissions/:submissionId', ({ request, params }) => json(request, submissionDetail(String(params.submissionId)))),
  http.get('/api/v1/submissions/:submissionId/criteria/:criterionId', ({ request, params }) => {
    const noData = String(params.submissionId) === 's-north' && String(params.criterionId) === 'c-design'
    return json(request, { criterion_id: String(params.criterionId), criterion_name: noData ? 'Опыт пользователя' : 'Качество реализации', team_name: 'Север', status: noData ? 'no_data' : 'scored', score: noData ? null : 8, max_score: 10, agent_score: noData ? null : 8, agent: 'design', justification: noData ? undefined : 'Основной сценарий проходит без ошибок.', no_data_reason: noData ? 'Хост и скринкаст недоступны.' : undefined, confidence: noData ? 0 : 0.84, evidence: [], flags: [], run_id: 'run-demo', version: 1 })
  }),
  http.put('/api/v1/submissions/:submissionId/criteria/:criterionId/override', ({ request }) => json(request, { criterion_id: 'c-code', criterion_name: 'Качество реализации', status: 'scored', score: 9, max_score: 10, agent_score: 8, agent: 'code', justification: 'Ручная корректировка организатора.', confidence: 1, evidence: [], flags: [], override: { score: 9, reason: 'Уточнено после демо', at: now }, run_id: 'run-demo', version: 2 })),
  http.get('/api/v1/projects/:projectId/runs', ({ request }) => json(request, { items: [{ id: 'run-demo', project_id: 'p-good', status: 'completed', rubric_version: 3, tasks: [{ submission_id: 's-aurora', role: 'code', state: 'done', attempt: 1 }, { submission_id: 's-north', role: 'design', state: 'no_data', attempt: 1, reason: 'Хост недоступен' }], tokens_in: 18320, tokens_out: 4920, cost_usd: 4.82, created_at: now, finished_at: now }] })),
  http.post('/api/v1/projects/:projectId/runs', ({ request }) => json(request, { id: 'run-new', project_id: 'p-spring', status: 'queued', rubric_version: 3, tasks: [], tokens_in: null, tokens_out: null, cost_usd: null, created_at: now, finished_at: null }, 202)),
  http.get('/api/v1/runs/:runId', ({ request, params }) => json(request, { id: String(params.runId), project_id: 'p-good', status: 'running', rubric_version: 3, tasks: [{ submission_id: 's-aurora', role: 'code', state: 'running', attempt: 1 }, { submission_id: 's-north', role: 'design', state: 'no_data', attempt: 1, reason: 'Хост недоступен' }], created_at: now, finished_at: null })),
  http.get('/api/v1/runs/:runId/journal', ({ request }) => json(request, { items: [{ id: 'evt-1', seq: 1, at: now, event: 'post_llm_call', run_id: 'run-demo', role: 'code', payload: { status: 'completed' } }], next_cursor: null })),
  http.get('/api/v1/projects/:projectId/leaderboard', ({ request, params }) => json(request, { project_id: String(params.projectId), rubric_version: 3, generated_at: now, stale_criteria: [], criteria: criteria.map(({ id, name, weight, max_score, agent }) => ({ id, name, weight, max_score, agent })), rows: submissions.map((item, index) => ({ submission_id: item.id, team_name: item.team_name, rank: index + 1, total: index === 1 ? null : 82.5 - index * 8, complete: item.completeness === 'complete', cells: Object.fromEntries(criteria.map((criterion) => [criterion.id, { status: item.id === 's-north' && criterion.id === 'c-design' ? 'no_data' : 'scored', score: item.id === 's-north' && criterion.id === 'c-design' ? null : 8, max_score: 10, overridden: false, stale: false }])), flags: item.flags })) })),
  http.get('/api/v1/projects/:projectId/export.csv', () => new HttpResponse('\ufeffteam_name,total\nАврора,82.5\n', { headers: { 'Content-Type': 'text/csv; charset=utf-8' } })),
  http.get('/api/v1/projects/:projectId/events', () => new HttpResponse('id: 1\nevent: message.created\ndata: {"message_id":"msg-2"}\n\n', { headers: { 'Content-Type': 'text/event-stream' } })),
]
