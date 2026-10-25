import { useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Check, History, Plus, Save, Trash2 } from 'lucide-react'
import type { CriterionInput, RubricState, ScoringRole } from '../../api/types'
import { api } from '../../api/client'

type RubricPageProps = { projectId: string }
type DraftCriterion = CriterionInput & { id: string }
const roles: ScoringRole[] = ['code', 'business', 'design', 'critic-uniqueness', 'critic-honesty']
const roleLabels: Record<ScoringRole, string> = { code: 'Программист', business: 'Бизнес-эксперт', design: 'Дизайнер', 'critic-uniqueness': 'Критик · оригинальность', 'critic-honesty': 'Критик · честность', human: 'Организатор' }

function toDraft(state: RubricState | null): DraftCriterion[] { return state?.current?.criteria.map((criterion) => ({ ...criterion, weight: criterion.weight * 100 })) ?? [] }

export function RubricPage({ projectId }: RubricPageProps) {
  const [state, setState] = useState<RubricState | null>(null)
  const [criteria, setCriteria] = useState<DraftCriterion[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')
  const [historyOpen, setHistoryOpen] = useState(false)

  useEffect(() => { let cancelled = false; setLoading(true); api.getRubric(projectId).then((result) => { if (!cancelled) { setState(result); setCriteria(toDraft(result)) } }).catch(() => !cancelled && setMessage('Не удалось загрузить рубрику')).finally(() => !cancelled && setLoading(false)); return () => { cancelled = true } }, [projectId])

  const totalWeight = useMemo(() => criteria.reduce((sum, criterion) => sum + Number(criterion.weight || 0), 0), [criteria])
  const blocked = loading || criteria.length === 0 || Math.round(totalWeight) !== 100 || !state?.current
  const update = (id: string, patch: Partial<DraftCriterion>) => setCriteria((items) => items.map((item) => item.id === id ? { ...item, ...patch } : item))
  const add = () => setCriteria((items) => [...items, { id: `new-${Date.now()}`, name: 'Новый критерий', description: '', weight: 0, max_score: 10, agent: 'business' }])
  const remove = (id: string) => setCriteria((items) => items.filter((item) => item.id !== id))
  const save = async () => { if (!state?.current) return; setSaving(true); setMessage(''); try { const result = await api.saveRubric(projectId, { expected_version: state.current.version, criteria: criteria.map(({ id, ...criterion }) => ({ ...criterion, weight: Number(criterion.weight) / 100 })) }); setState((current) => current ? { ...current, current: result } : current); setCriteria(toDraft({ current: result, versions: state.versions })); setMessage('Черновик сохранён') } catch { setMessage('Конфликт версии или ошибка сохранения') } finally { setSaving(false) } }
  const confirm = async () => { if (!state?.current || blocked) return; setSaving(true); try { const result = await api.confirmRubric(projectId, state.current.version); setState((current) => current ? { ...current, current: result } : current); setMessage('Рубрика подтверждена') } catch { setMessage('Не удалось подтвердить рубрику') } finally { setSaving(false) } }

  return <div className="page-content rubric-page"><div className="eyebrow"><span className={blocked ? 'status-dot amber' : 'live-dot'} /> Настройка критериев оценки</div><div className="page-title-row"><div><h1>Рубрика</h1><p className="page-lead">Проверьте критерии до запуска агентов. Сумма весов должна быть равна 100%.</p></div><div className="button-row"><button className="outline-button" onClick={() => setHistoryOpen((value) => !value)}><History size={15} /> История версий</button><button className="solid-button" onClick={save} disabled={saving || blocked}><Save size={15} /> {saving ? 'Сохраняем…' : 'Сохранить'}</button></div></div>{historyOpen && <section className="dark-card rubric-history"><h2>История версий</h2>{state?.versions.map((version) => <div className="rubric-history-row" key={version.version}><span>Версия {version.version}</span><Status>{version.status}</Status><time>{new Date(version.created_at).toLocaleDateString('ru-RU')}</time></div>)}</section>}{blocked && <div className="blocking-banner" role="alert"><AlertTriangle size={18} /><span><b>Запуск невозможен.</b> {criteria.length === 0 ? 'Добавьте хотя бы один критерий.' : `Сумма весов сейчас ${Math.round(totalWeight)}%, нужно 100%.`}</span></div>}<section className="dark-card rubric-card"><div className="rubric-table rubric-head"><span>Критерий</span><span>Вес</span><span>Шкала</span><span>Агент</span><span aria-hidden="true" /></div>{criteria.map((criterion) => <div className="rubric-table rubric-row" key={criterion.id}><input aria-label="Название критерия" value={criterion.name} onChange={(event) => update(criterion.id, { name: event.target.value })} /><label><input type="number" min="0" max="100" value={criterion.weight} onChange={(event) => update(criterion.id, { weight: Number(event.target.value) })} />%</label><input aria-label="Максимальный балл" type="number" min="1" max="100" value={criterion.max_score} onChange={(event) => update(criterion.id, { max_score: Number(event.target.value) })} /><select aria-label="Агент критерия" value={criterion.agent} onChange={(event) => update(criterion.id, { agent: event.target.value as ScoringRole })}>{roles.map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}</select><button className="icon-button danger-icon" aria-label={`Удалить ${criterion.name}`} onClick={() => remove(criterion.id)}><Trash2 size={16} /></button></div>)}<button className="outline-button rubric-add" onClick={add}><Plus size={15} /> Добавить критерий</button></section>{message && <p className="rubric-message" role="status"><Check size={15} />{message}</p>}<div className="rubric-footer"><span>Всего: <b>{Math.round(totalWeight)}%</b></span><button className="solid-button" onClick={confirm} disabled={saving || blocked || state?.current?.status === 'confirmed'}><Check size={15} /> Подтвердить рубрику</button></div></div>
}

function Status({ children }: { children: string }) { return <span className="status-pill tone-muted">{children === 'superseded' ? 'устарела' : children === 'confirmed' ? 'подтверждена' : 'черновик'}</span> }
