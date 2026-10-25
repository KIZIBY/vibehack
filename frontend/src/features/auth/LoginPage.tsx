import { useState } from 'react'
import { AlertTriangle, ArrowUpRight, Sparkles } from 'lucide-react'
import { ApiError, api } from '../../api/client'

export function LoginPage({ onLogin }: { onLogin: () => void }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const submit = async (event: React.FormEvent) => {
    event.preventDefault(); setError(''); setBusy(true)
    try { await api.login(username, password); localStorage.setItem('judge_session_present', '1'); onLogin() }
    catch (cause) { if (cause instanceof ApiError && cause.status === 429) setError('Слишком много попыток. Попробуйте ещё раз через минуту.'); else setError('Неверный логин или пароль.') }
    finally { setBusy(false) }
  }
  return <main className="login-shell"><div className="login-glow" /><section className="login-card"><div className="login-brand"><div className="brand-orb"><Sparkles size={18} /></div><span>Консилиум</span></div><div className="login-copy"><p className="eyebrow">ДЕМО-ДОСТУП</p><h1>С возвращением, Анна</h1><p>Войдите, чтобы продолжить работу с жюри и результатами оценки.</p></div><form onSubmit={submit} className="login-form"><label>Логин<input autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} placeholder="Введите логин" required /></label><label>Пароль<input autoComplete="current-password" type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Введите пароль" required /></label>{error && <div className="login-error" role="alert"><AlertTriangle size={16} /> {error}</div>}<button className="solid-button login-submit" disabled={busy}>{busy ? 'Проверяем…' : 'Войти в рабочее пространство'} <ArrowUpRight size={16} /></button></form><p className="login-hint">Демо-учётные данные выдаёт организатор хакатона.</p></section></main>
}
