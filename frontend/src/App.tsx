import { useCallback, useEffect, useState } from 'react'
import {
  ChevronDown, ClipboardList, FolderOpen, ListChecks, MessageSquare, Moon, Play, Plus, Search,
  Settings2, Sparkles, Sun, Trophy, Users,
} from 'lucide-react'
import { api } from './api/client'
import type { Project, Role, Run } from './api/types'
import { LoginPage } from './features/auth/LoginPage'
import { ChatPage as InteractiveChatPage } from './features/chat/ChatPage'
import { RubricPage } from './features/rubric/RubricPage'
import { SubmissionsPage } from './features/submissions/SubmissionsPage'
import { RunsPage } from './features/runs/RunsPage'
import { LeaderboardPage as InteractiveLeaderboardPage } from './features/leaderboard/LeaderboardPage'
import { JournalPage as InteractiveJournalPage } from './features/journal/JournalPage'

type Page = 'chat' | 'rubric' | 'submissions' | 'runs' | 'agents' | 'leaderboard' | 'journal'
type ProjectType = Project['type']
type ProjectNav = { id: string; name: string; meta: string; type: ProjectType; version: number }
const typeLabels: Record<ProjectType, string> = { product_hackathon: 'Продуктовый хакатон', ml_hackathon: 'ML-хакатон', homework: 'Домашнее задание', other: 'Проект' }
const statusLabels: Record<string, string> = { setup: 'настройка', intake: 'приём решений', evaluating: 'идёт проверка', results: 'есть результаты', archived: 'в архиве' }
const toNav = (item: Project): ProjectNav => ({ id: item.id, name: item.name, type: item.type, version: item.version, meta: `${typeLabels[item.type]} · ${statusLabels[item.status] ?? item.status}` })
const roleLabels: Record<Role, string> = { rubric: 'Рубрика', sorter: 'Сортировщик', code: 'Программист', business: 'Бизнес-эксперт', design: 'Дизайнер', 'critic-uniqueness': 'Критик · оригинальность', 'critic-honesty': 'Критик · честность' }
const taskLabels = { queued: 'В очереди', running: 'Работает', done: 'Готово', failed: 'Ошибка', no_data: 'Нет данных' } as const

function StatusPill({ children, tone = 'teal' }: { children: React.ReactNode; tone?: 'teal' | 'amber' | 'muted' }) { return <span className={`status-pill ${tone}`}>{children}</span> }

function Sidebar({ page, setPage, projects, project, setProject, onCreate }: { page: Page; setPage: (page: Page) => void; projects: ProjectNav[]; project: number; setProject: (value: number) => void; onCreate: () => void }) {
  const nav = [['chat', 'Чат проекта', MessageSquare], ['rubric', 'Рубрика', ClipboardList], ['submissions', 'Решения', FolderOpen], ['runs', 'Запуски', Play], ['agents', 'Агенты', Users], ['leaderboard', 'Лидерборд', Trophy], ['journal', 'Журнал оценок', ListChecks]] as const
  return <aside className="app-sidebar"><div className="brand-row"><div className="brand-orb"><Sparkles size={15} /></div><span>Консилиум</span><button className="icon-button ml-auto" aria-label="Поиск"><Search size={18} /></button></div><button className="new-project" onClick={onCreate}><Plus size={17} /> Новый проект</button><div className="side-label">Текущий проект</div><nav className="side-nav">{nav.map(([id, label, Icon]) => <button key={id} className={page === id ? 'active' : ''} onClick={() => setPage(id)}><Icon size={17} />{label}</button>)}</nav><div className="side-divider" /><div className="side-label">Проекты</div><div className="project-list">{projects.map((item, index) => { return <button key={item.id} className={project === index ? 'selected' : ''} onClick={() => setProject(index)}><span className="project-dot" /><span><b>{item.name}</b><small>{item.meta}</small></span></button> })}</div><div className="side-footer"><button><Settings2 size={16} /> Настройки</button><button><span>?</span> Помощь</button></div></aside>
}

function ProjectHeader({ page, setPage, name }: { page: Page; setPage: (page: Page) => void; name: string }) {
  const tabs: [Page, string][] = [['chat', 'Чат'], ['rubric', 'Рубрика'], ['submissions', 'Решения'], ['runs', 'Запуски'], ['agents', 'Агенты'], ['leaderboard', 'Лидерборд'], ['journal', 'Журнал']]
  return <header className="project-header"><button className="project-switch"><Trophy size={16} /> {name} <ChevronDown size={14} /></button><nav className="top-tabs">{tabs.map(([id, label]) => <button key={id} className={page === id ? 'active' : ''} onClick={() => setPage(id)}>{label}</button>)}<button className="profile" aria-label="Профиль">А</button></nav></header>
}

function AgentsPage({ projectId }: { projectId: string }) {
  const [run, setRun] = useState<Run | null>(null)
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading')
  useEffect(() => {
    let alive = true
    setState('loading')
    api.listRuns(projectId).then((result) => { if (alive) { setRun(result.items[0] ?? null); setState('ready') } }).catch(() => { if (alive) setState('error') })
    return () => { alive = false }
  }, [projectId])
  if (state === 'loading') return <div className="page-content"><p className="page-lead">Загружаем состояние агентов…</p></div>
  if (state === 'error') return <div className="page-content"><p className="dialog-error">Не удалось загрузить состояние агентов</p></div>
  const roles = [...new Set((run?.tasks ?? []).map((task) => task.role))]
  return <div className="page-content"><div className="page-title-row"><div><h1>Агенты за работой</h1><p className="page-lead">{run ? `Последний запуск ${run.id} · ${run.status}` : 'Запусков пока не было. Запустите оценку на вкладке «Запуски».'}</p></div></div><div className="agent-grid">{roles.map((role) => { const tasks = (run?.tasks ?? []).filter((task) => task.role === role); const done = tasks.filter((task) => task.state === 'done' || task.state === 'no_data').length; const failed = tasks.some((task) => task.state === 'failed'); const running = tasks.some((task) => task.state === 'running'); const label = failed ? taskLabels.failed : running ? taskLabels.running : done === tasks.length ? taskLabels.done : taskLabels.queued; return <article className="agent-card" key={role}><div className="agent-card-main"><div className="agent-card-head"><b>{roleLabels[role]}</b><StatusPill tone={failed || running ? 'amber' : done === tasks.length ? 'teal' : 'muted'}>{label}</StatusPill></div><p>{done} из {tasks.length} задач</p><div className="mini-progress"><span style={{ width: `${tasks.length ? Math.round((done / tasks.length) * 100) : 0}%` }} /></div></div></article> })}</div></div>
}

function ProjectDialog({ mode, project, onClose, onSave, onArchive }: { mode: 'create' | 'rename' | 'archive'; project?: ProjectNav; onClose: () => void; onSave: (name: string, type: ProjectNav['type']) => Promise<void>; onArchive: () => Promise<void> }) {
  const [name, setName] = useState(project?.name ?? '')
  const [type, setType] = useState<ProjectNav['type']>(project?.type ?? 'product_hackathon')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const save = async () => { if (!name.trim()) { setError('Введите название проекта'); return }; setBusy(true); setError(''); try { await onSave(name.trim(), type) } catch { setError('Не удалось сохранить проект') } finally { setBusy(false) } }
  const archive = async () => { setBusy(true); try { await onArchive() } catch { setError('Не удалось архивировать проект') } finally { setBusy(false) } }
  return <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}><section className="project-dialog" role="dialog" aria-modal="true"><div className="dialog-header"><h2>{mode === 'create' ? 'Новый проект' : mode === 'rename' ? 'Переименовать проект' : 'Архивировать проект?'}</h2><button className="icon-button" onClick={onClose} aria-label="Закрыть">×</button></div>{mode === 'archive' ? <><p className="dialog-copy">Проект «{project?.name}» исчезнет из активного списка, но его результаты останутся доступны в архиве.</p><div className="dialog-actions"><button className="outline-button" onClick={onClose}>Отмена</button><button className="danger-button" onClick={archive} disabled={busy}>{busy ? 'Архивируем…' : 'Архивировать'}</button></div></> : <><label className="dialog-label">Название<input autoFocus value={name} onChange={(event) => setName(event.target.value)} placeholder="Например, Весенний хакатон" /></label>{mode === 'create' && <label className="dialog-label">Тип<select value={type} onChange={(event) => setType(event.target.value as ProjectNav['type'])}><option value="product_hackathon">Продуктовый хакатон</option><option value="ml_hackathon">ML-хакатон</option><option value="homework">Домашнее задание</option><option value="other">Другое</option></select></label>}{error && <p className="dialog-error">{error}</p>}<div className="dialog-actions">{mode === 'rename' && <button className="danger-link" onClick={archive} disabled={busy}>Архивировать</button>}<button className="outline-button" onClick={onClose}>Отмена</button><button className="solid-button" onClick={save} disabled={busy}>{busy ? 'Сохраняем…' : mode === 'create' ? 'Создать проект' : 'Сохранить'}</button></div></>}</section></div>
}

export function App() {
  const [auth, setAuth] = useState<'checking' | 'signed-out' | 'signed-in'>(() => localStorage.getItem('judge_session_present') ? 'checking' : 'signed-out')
  const [page, setPage] = useState<Page>('chat'); const [project, setProject] = useState(0); const [light, setLight] = useState(false); const [projectList, setProjectList] = useState<ProjectNav[]>([]); const [dialog, setDialog] = useState<'create' | 'rename' | 'archive' | null>(null)
  const [projectsState, setProjectsState] = useState<'loading' | 'ready' | 'error'>('loading')
  useEffect(() => { if (auth !== 'checking') return; api.me().then(() => setAuth('signed-in')).catch(() => { localStorage.removeItem('judge_session_present'); setAuth('signed-out') }) }, [auth])
  const loadProjects = useCallback(() => { setProjectsState('loading'); api.listProjects().then((result) => { setProjectList(result.items.map(toNav)); setProject(0); setProjectsState('ready') }).catch(() => setProjectsState('error')) }, [])
  useEffect(() => { if (auth === 'signed-in') loadProjects() }, [auth, loadProjects])
  if (auth === 'checking') return <main className="auth-loading"><div className="brand-orb"><Sparkles size={17} /></div><span>Проверяем сессию…</span></main>
  if (auth === 'signed-out') return <LoginPage onLogin={() => setAuth('signed-in')} />
  const logout = async () => { try { await api.logout() } finally { localStorage.removeItem('judge_session_present'); setAuth('signed-out') } }
  const selectedProject = projectList[project] ?? projectList[0]
  const createProject = async (name: string, type: ProjectType) => { const created = await api.createProject({ name, type }); setProjectList((items) => [...items, toNav(created)]); setProject(projectList.length); setDialog(null) }
  const renameProject = async (name: string) => { if (!selectedProject) return; const updated = await api.updateProject(selectedProject.id, { name, expected_version: selectedProject.version }); setProjectList((items) => items.map((item) => item.id === selectedProject.id ? toNav(updated) : item)); setDialog(null) }
  const archiveProject = async () => { if (!selectedProject) return; await api.updateProject(selectedProject.id, { archived: true, expected_version: selectedProject.version }); setProjectList((items) => items.filter((item) => item.id !== selectedProject.id)); setProject(0); setDialog(null) }
  const id = selectedProject?.id
  const pageContent = projectsState === 'loading' ? <div className="page-content"><p className="page-lead">Загружаем проекты…</p></div>
    : projectsState === 'error' ? <div className="page-content"><p className="dialog-error">Не удалось загрузить проекты</p><button className="outline-button" onClick={loadProjects}>Повторить</button></div>
    : !id ? <div className="page-content"><h1>Создайте проект</h1><p className="page-lead">Проектов пока нет. Создайте первый, чтобы добавить материалы, рубрику и решения.</p><button className="solid-button" onClick={() => setDialog('create')}><Plus size={15} /> Новый проект</button></div>
    : page === 'chat' ? <InteractiveChatPage key={id} projectId={id} /> : page === 'rubric' ? <RubricPage key={id} projectId={id} /> : page === 'submissions' ? <SubmissionsPage key={id} projectId={id} /> : page === 'runs' ? <RunsPage key={id} projectId={id} /> : page === 'agents' ? <AgentsPage key={id} projectId={id} /> : page === 'leaderboard' ? <InteractiveLeaderboardPage key={id} projectId={id} /> : <InteractiveJournalPage key={id} projectId={id} />
  return <div className={`app-shell ${light ? 'light-mode' : ''}`}><Sidebar page={page} setPage={setPage} projects={projectList} project={project} setProject={setProject} onCreate={() => { if (projectsState === 'ready') setDialog('create') }} /><main className="app-main"><ProjectHeader page={page} setPage={setPage} name={selectedProject?.name ?? 'Проект'} /><div className="mobile-toolbar"><button className="project-switch"><Trophy size={16} /> {selectedProject?.name} <ChevronDown size={14} /></button><button className="icon-button" onClick={() => setLight(!light)} aria-label="Сменить тему">{light ? <Moon size={17} /> : <Sun size={17} />}</button></div>{pageContent}<div className="theme-toggle"><button className="icon-button" onClick={() => setLight(!light)} aria-label="Сменить тему">{light ? <Moon size={16} /> : <Sun size={16} />}</button><button className="icon-button" onClick={() => setDialog('rename')} disabled={!selectedProject} aria-label="Переименовать проект">✎</button><button className="icon-button" onClick={logout} aria-label="Выйти">↪</button></div></main>{dialog && <ProjectDialog mode={dialog} project={selectedProject} onClose={() => setDialog(null)} onSave={dialog === 'create' ? createProject : renameProject} onArchive={archiveProject} />}</div>
}
