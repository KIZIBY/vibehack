import { useEffect, useRef, useState } from 'react'
import { ArrowUpRight, Bot, FileText, Link2, Paperclip, Send, Sparkles, X } from 'lucide-react'
import type { Message } from '../../api/types'
import { api } from '../../api/client'

type ChatPageProps = { projectId: string }

function formatTime(value: string) {
  return new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(new Date(value))
}

function messageClass(message: Message) {
  if (message.author === 'organizer') return 'message user-message'
  if (message.author === 'agent') return 'message agent-message'
  return 'message agent-message system-message'
}

export function ChatPage({ projectId }: ChatPageProps) {
  const [messages, setMessages] = useState<Message[]>([])
  const [nextCursor, setNextCursor] = useState<string | null>(null)
  const [text, setText] = useState('')
  const [files, setFiles] = useState<File[]>([])
  const [links, setLinks] = useState<string[]>([])
  const [linkDraft, setLinkDraft] = useState('')
  const [showLinkInput, setShowLinkInput] = useState(false)
  const [loading, setLoading] = useState(true)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState('')
  const fileInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setMessages([])
    setNextCursor(null)
    api.listMessages(projectId, undefined, 50).then((response) => {
      if (cancelled) return
      setMessages(response.items)
      setNextCursor(response.next_cursor)
    }).catch(() => !cancelled && setError('Не удалось загрузить историю чата')).finally(() => !cancelled && setLoading(false))
    return () => { cancelled = true }
  }, [projectId])

  const loadOlder = async () => {
    if (!nextCursor || loading) return
    setLoading(true)
    try {
      const response = await api.listMessages(projectId, nextCursor, 50)
      setMessages((current) => [...response.items, ...current])
      setNextCursor(response.next_cursor)
    } catch { setError('Не удалось загрузить предыдущие сообщения') } finally { setLoading(false) }
  }

  const addFiles = (incoming: FileList | File[]) => {
    setFiles((current) => [...current, ...Array.from(incoming).filter((file) => !current.some((item) => item.name === file.name && item.size === file.size))])
  }

  const addLink = () => {
    const value = linkDraft.trim()
    if (!value || links.includes(value)) return
    try { new URL(value) } catch { setError('Ссылка должна начинаться с http:// или https://'); return }
    setLinks((current) => [...current, value])
    setLinkDraft('')
    setShowLinkInput(false)
    setError('')
  }

  const send = async () => {
    if (!text.trim() && files.length === 0 && links.length === 0) return
    setSending(true)
    setError('')
    try {
      if (files.length || links.length) {
        const form = new FormData()
        files.forEach((file) => form.append('files', file))
        links.forEach((link) => form.append('links', link))
        await api.uploadBriefs(projectId, form)
      }
      if (text.trim()) {
        const message = await api.postMessage(projectId, text.trim())
        setMessages((current) => [...current, message])
      }
      setText('')
      setFiles([])
      setLinks([])
    } catch { setError('Не удалось отправить сообщение или вложения') } finally { setSending(false) }
  }

  return <div className="page-content chat-page">
    <div className="eyebrow"><span className="live-dot" /> Проект запущен · сообщения синхронизируются</div>
    <h1>Чат проекта</h1>
    <p className="page-lead">Добавьте вводные, решения участников или поправьте критерии — агенты соберут всё в одном месте.</p>
    <div className="chat-stream" onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); addFiles(event.dataTransfer.files) }}>
      {nextCursor && <button className="outline-button chat-load-more" onClick={loadOlder} disabled={loading}>Загрузить предыдущие сообщения</button>}
      {loading && messages.length === 0 && <div className="empty-state">Загружаем историю чата…</div>}
      {!loading && messages.length === 0 && <div className="empty-state">Сообщений пока нет. Добавьте первую вводную.</div>}
      {messages.map((message) => <article className={messageClass(message)} key={message.id}>
        {message.author !== 'organizer' && <div className="message-author"><span className={`agent-avatar ${message.author === 'agent' ? 'teal' : 'muted'}`}>{message.author === 'agent' ? <Sparkles size={15} /> : <Bot size={15} />}</span><b>{message.author === 'agent' ? 'Агент' : 'Система'}</b><span>{formatTime(message.created_at)}</span></div>}
        <div>{message.text}</div>
        {message.attachments?.map((attachment) => <div className="attachment" key={attachment.name}><FileText size={17} /> {attachment.name}</div>)}
        {message.author === 'organizer' && <small>Вы · {formatTime(message.created_at)}</small>}
      </article>)}
      {error && <p className="dialog-error" role="alert">{error}</p>}
    </div>
    {(files.length > 0 || links.length > 0) && <div className="chat-attachment-list" aria-label="Выбранные вложения">
      {files.map((file) => <span className="chat-attachment-chip" key={`${file.name}-${file.size}`}><Paperclip size={14} />{file.name}<button onClick={() => setFiles((current) => current.filter((item) => item !== file))} aria-label={`Удалить ${file.name}`}><X size={13} /></button></span>)}
      {links.map((link) => <span className="chat-attachment-chip" key={link}><Link2 size={14} />{link}<button onClick={() => setLinks((current) => current.filter((item) => item !== link))} aria-label={`Удалить ${link}`}><X size={13} /></button></span>)}
    </div>}
    {showLinkInput && <div className="chat-link-row"><input autoFocus value={linkDraft} onChange={(event) => setLinkDraft(event.target.value)} onKeyDown={(event) => event.key === 'Enter' && addLink()} placeholder="https://example.com" /><button className="outline-button" onClick={addLink}>Добавить</button></div>}
    <div className="composer"><input type="file" multiple ref={fileInput} hidden onChange={(event) => event.target.files && addFiles(event.target.files)} /><button className="icon-button" aria-label="Прикрепить файлы" onClick={() => fileInput.current?.click()}><Paperclip size={19} /></button><button className="icon-button" aria-label="Добавить ссылку" onClick={() => setShowLinkInput((value) => !value)}><Link2 size={18} /></button><input value={text} onChange={(event) => setText(event.target.value)} onKeyDown={(event) => event.key === 'Enter' && !event.shiftKey && (event.preventDefault(), send())} placeholder="Добавьте решения, поправьте критерии или спросите агентов…" /><button className="send-button" aria-label="Отправить" onClick={send} disabled={sending}><Send size={17} /></button></div>
    <p className="chat-drop-hint">Перетащите файлы в ленту или добавьте ссылку кнопкой рядом с вложениями.</p>
    <button className="outline-button" onClick={() => setText('Откройте полную рубрику для редактирования критериев.')}><ArrowUpRight size={15} /> Открыть полную рубрику</button>
  </div>
}
