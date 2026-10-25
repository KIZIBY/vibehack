import { useEffect, useRef, useState } from 'react'
import { AlertTriangle, CheckCircle2, FileArchive, FileUp, FolderOpen } from 'lucide-react'
import type { SubmissionSummary } from '../../api/types'
import { api } from '../../api/client'

export function SubmissionsPage({ projectId }: { projectId: string }) {
  const [items, setItems] = useState<SubmissionSummary[]>([])
  const [rejected, setRejected] = useState<{ row: string; reason: string }[]>([])
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const [message, setMessage] = useState('')
  const singleInput = useRef<HTMLInputElement>(null)
  const batchInput = useRef<HTMLInputElement>(null)

  const refresh = () => api.listSubmissions(projectId).then((result) => setItems(result.items)).catch(() => setMessage('Не удалось загрузить решения')).finally(() => setLoading(false))
  useEffect(() => { setLoading(true); refresh() }, [projectId])

  const upload = async (file: File, batch: boolean) => {
    setUploading(true); setMessage(''); setRejected([])
    const form = new FormData(); form.append(batch ? 'file' : 'submission', file)
    try {
      if (batch) { const result = await api.createSubmissionsBatch(projectId, form); setRejected(result.rejected); setMessage(`Загружено решений: ${result.items.length}`) } else { await api.createSubmission(projectId, form); setMessage('Работа добавлена в очередь обработки') }
      await refresh()
    } catch { setMessage('Не удалось загрузить файл') } finally { setUploading(false) }
  }

  return <div className="page-content submissions-page"><div className="eyebrow"><span className="live-dot" /> Приём материалов участников</div><div className="page-title-row"><div><h1>Решения</h1><p className="page-lead">Загрузите работу одной команды или таблицу с пачкой решений. Недостающие материалы будут отмечены до запуска оценки.</p></div><div className="button-row"><input ref={singleInput} hidden type="file" onChange={(event) => event.target.files?.[0] && upload(event.target.files[0], false)} /><input ref={batchInput} hidden type="file" accept=".csv,.xlsx,.zip" onChange={(event) => event.target.files?.[0] && upload(event.target.files[0], true)} /><button className="outline-button" onClick={() => batchInput.current?.click()} disabled={uploading}><FileArchive size={15} /> Пачкой</button><button className="solid-button" onClick={() => singleInput.current?.click()} disabled={uploading}><FileUp size={15} /> Одну работу</button></div></div>{message && <div className="upload-message" role="status">{message}</div>}{rejected.length > 0 && <div className="blocking-banner"><AlertTriangle size={18} /><span><b>Строки не приняты:</b> {rejected.map((item) => `${item.row} — ${item.reason}`).join('; ')}</span></div>}<section className="submission-grid">{loading && <div className="empty-state">Загружаем список решений…</div>}{!loading && items.length === 0 && <div className="empty-state"><FolderOpen size={24} /> Решений пока нет</div>}{items.map((item) => <article className="dark-card submission-card" key={item.id}><div className="submission-card-head"><div><h2>{item.team_name}</h2><span className="submission-id">{item.id}</span></div><SubmissionStatus value={item.evaluation_status} /></div><div className={`completeness ${item.completeness === 'complete' ? 'complete' : 'incomplete'}`}>{item.completeness === 'complete' ? <CheckCircle2 size={16} /> : <AlertTriangle size={16} />} {item.completeness === 'complete' ? 'Материалы полные' : 'Материалы неполные'}</div>{item.missing?.length ? <p className="missing-materials">Не хватает: {item.missing.join(', ')}</p> : <p className="missing-materials">Все обязательные материалы доступны</p>}<div className="submission-card-footer"><span>{item.flags.length ? `${item.flags.length} флага` : 'Без флагов'}</span><button className="outline-button">Открыть опись</button></div></article>)}</section></div>
}

function SubmissionStatus({ value }: { value: SubmissionSummary['evaluation_status'] }) { const labels = { not_started: 'Не запускалась', running: 'В работе', done: 'Готово', partial: 'Частично', failed: 'Ошибка' }; return <span className={`status-pill ${value === 'done' ? 'teal' : value === 'failed' ? 'amber' : 'muted'}`}>{labels[value]}</span> }
