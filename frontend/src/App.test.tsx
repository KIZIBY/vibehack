import { render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'

const ULID = '01M5SNQTZ4KR60WCDMT2DV1KFW'
const HARDCODED = ['p-spring', 'p-good', 'p-homework', 'p-algo']
const project = { id: ULID, name: 'Дичь', type: 'other', version: 1, archived: false, created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' }

let calls: string[] = []

function stubApi(projectsReply: () => Response) {
  calls = []
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url
    const path = url.replace(/^https?:\/\/[^/]+/, '')
    calls.push(path)
    const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
    if (path.startsWith('/api/v1/auth/me')) return json({ username: 'admin' })
    if (/^\/api\/v1\/projects(\?|$)/.test(path)) return projectsReply()
    if (path.includes('/rubric')) return json({ current: null, draft: null, versions: [] })
    if (path.includes('/messages')) return json({ items: [], next_cursor: null })
    return json({ items: [], next_cursor: null })
  }))
}
const ok = (body: unknown) => () => new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })

beforeEach(() => { localStorage.setItem('judge_session_present', '1') })
afterEach(() => { vi.unstubAllGlobals() })

describe('App: реальные проекты из API', () => {
  it('запрашивает /api/v1/projects и показывает только проекты из ответа', async () => {
    stubApi(ok({ items: [project] }))
    render(<App />)
    await waitFor(() => expect(calls.some((c) => c.startsWith('/api/v1/projects?') || c === '/api/v1/projects')).toBe(true))
    expect((await screen.findAllByText('Дичь')).length).toBeGreaterThan(0)
    expect(screen.queryByText(/Город будущего/)).not.toBeInTheDocument()
    expect(screen.queryByText('Алгоритмы и структуры данных')).not.toBeInTheDocument()
  })

  it('запросы страниц идут с ULID, без зашитых id', async () => {
    stubApi(ok({ items: [project] }))
    render(<App />)
    await waitFor(() => expect(calls.some((c) => c.startsWith(`/api/v1/projects/${ULID}/`))).toBe(true))
    for (const c of calls) for (const h of HARDCODED) expect(c).not.toContain(h)
  })

  it('пустой список: призыв создать проект и ни одного запроса по id проекта', async () => {
    stubApi(ok({ items: [] }))
    render(<App />)
    expect(await screen.findByText(/Создайте проект/)).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 50))
    expect(calls.filter((c) => /^\/api\/v1\/projects\/[^?]/.test(c))).toEqual([])
  })

  it('500 на списке: сообщение об ошибке и нет запросов по id проекта', async () => {
    stubApi(() => new Response(JSON.stringify({ detail: 'boom' }), { status: 500, headers: { 'Content-Type': 'application/json' } }))
    render(<App />)
    expect(await screen.findByText(/Не удалось загрузить проекты/)).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 50))
    expect(calls.filter((c) => /^\/api\/v1\/projects\/[^?]/.test(c))).toEqual([])
  })
})
