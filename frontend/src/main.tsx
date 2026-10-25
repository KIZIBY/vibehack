import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'

async function start() {
  if (import.meta.env.DEV && import.meta.env.VITE_DISABLE_MOCKS !== 'true') {
    const { worker } = await import('./mocks/browser')
    await worker.start({ onUnhandledRequest: 'bypass' })
  }
  createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
}

void start()
