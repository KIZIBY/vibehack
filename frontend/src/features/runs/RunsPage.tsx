import { useEffect, useMemo, useRef, useState } from 'react'
import { CircleStop, Play, RefreshCw, RotateCcw, Wifi, WifiOff } from 'lucide-react'
import type { Run, Role } from '../../api/types'
import { api, projectEventsUrl } from '../../api/client'

const roles: Role[] = ['sorter', 'code', 'business', 'design', 'critic-uniqueness', 'critic-honesty']
const roleLabels: Record<Role, string> = { rubric: 'Рубрика', sorter: 'Сортировщик', code: 'Программист', business: 'Бизнес', design: 'Дизайнер', 'critic-uniqueness': 'Критик · оригинальность', 'critic-honesty': 'Критик · честность' }

export function RunsPage({ projectId }: { projectId: string }) {
  const [run, setRun] = useState<Run | null>(null)
  const [teams, setTeams] = useState<{ id: string; name: string }[]>([])
  const [starting, setStarting] = useState(false)
  const [connected, setConnected] = useState(false)
  const [error, setError] = useState('')
  const source = useRef<EventSource | null>(null)
  const retries = useRef(0)

  const reload = async () => { try { const [result, subs] = await Promise.all([api.listRuns(projectId), api.listSubmissions(projectId)]); setRun(result.items[0] ?? null); setTeams(subs.items.map((item) => ({ id: item.id, name: item.team_name }))) } catch { setError('Не удалось прочитать состояние запуска') } }
  useEffect(() => { reload(); const connect = () => { source.current?.close(); const eventSource = new EventSource(projectEventsUrl(projectId)); source.current = eventSource; eventSource.onopen = () => { retries.current = 0; setConnected(true) }; eventSource.onmessage = () => reload(); eventSource.onerror = () => { setConnected(false); eventSource.close(); if (retries.current < 4) { const delay = 1000 * 2 ** retries.current++; window.setTimeout(connect, delay) } else setError('SSE отключён, используйте обновление состояния') } }; connect(); return () => source.current?.close() }, [projectId])
  const start = async () => { setStarting(true); setError(''); try { const result = await api.startRun(projectId); setRun(result) } catch { setError('Нельзя запустить оценку: проверьте рубрику и решения') } finally { setStarting(false) } }
  const counts = useMemo(() => { const tasks = run?.tasks ?? []; return { done: tasks.filter((task) => task.state === 'done').length, total: tasks.length } }, [run])
  const stateFor = (submissionId: string, role: Role) => run?.tasks.find((task) => task.role === role && task.submission_id === submissionId)?.state ?? (run?.status === 'running' ? 'queued' : '—')

  return <div className="page-content runs-page"><div className="eyebrow"><span className={connected ? 'live-dot' : 'status-dot amber'} /> {connected ? 'События подключены' : 'Ожидаем подключение к событиям'}</div><div className="page-title-row"><div><h1>Запуск оценки</h1><p className="page-lead">Следите за обработкой решений по каждой роли. При обрыве соединения состояние перечитается автоматически.</p></div><div className="button-row"><button className="outline-button" onClick={reload}><RefreshCw size={15} /> Обновить</button><button className="solid-button" onClick={start} disabled={starting || run?.status === 'running'}><Play size={15} /> {starting ? 'Запускаем…' : 'Запустить проверку'}</button></div></div>{error && <p className="dialog-error" role="alert">{error}</p>}<section className="run-summary dark-card"><div><span>Текущий запуск</span><b>{run?.id ?? '—'}</b></div><div><span>Статус</span><RunStatus status={run?.status} /></div><div><span>Прогресс</span><b>{counts.done} / {counts.total || '—'} задач</b></div><div className="connection-state">{connected ? <Wifi size={16} /> : <WifiOff size={16} />} {connected ? 'SSE online' : 'reconnect'}</div></section><section className="dark-card run-grid-card"><div className="run-grid run-grid-head"><span>Команда</span>{roles.map((role) => <span key={role}>{roleLabels[role]}</span>)}</div>{teams.map((team) => <div className="run-grid" key={team.id}><b>{team.name}</b>{roles.map((role) => <RunCell key={`${team.id}-${role}`} state={stateFor(team.id, role)} />)}</div>)}</section>{run && <div className="run-actions"><button className="outline-button"><RotateCcw size={15} /> Перезапустить выбранную работу</button><button className="outline-button"><CircleStop size={15} /> Остановить запуск</button></div>}</div>
}

function RunCell({ state }: { state: string }) { const labels: Record<string, string> = { done: 'Готово', running: 'В работе', queued: 'В очереди', failed: 'Ошибка', no_data: 'Нет данных', '—': '—' }; return <span className={`run-cell ${state}`}>{labels[state] ?? state}</span> }
function RunStatus({ status }: { status?: Run['status'] }) { const labels = { queued: 'В очереди', running: 'В работе', completed: 'Завершён', partial: 'Частично', failed: 'Ошибка' }; return <span className={`status-pill ${status === 'completed' ? 'teal' : status === 'failed' ? 'amber' : 'muted'}`}>{status ? labels[status] : 'Нет запуска'}</span> }
