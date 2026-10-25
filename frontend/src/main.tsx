import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { shouldEnableMocks } from './mocks/enabled'

async function start() {
  if (shouldEnableMocks(import.meta.env)) {
    const { worker } = await import('./mocks/browser')
    await worker.start({ onUnhandledRequest: 'bypass' })
  }
  createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
}

void start()
