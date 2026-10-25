import { describe, expect, it } from 'vitest'
import { shouldEnableMocks } from './enabled'

describe('shouldEnableMocks', () => {
  const cases: { name: string; env: { DEV?: boolean; VITE_ENABLE_MOCKS?: string }; want: boolean }[] = [
    { name: 'DEV и флаг true', env: { DEV: true, VITE_ENABLE_MOCKS: 'true' }, want: true },
    { name: 'DEV без флага', env: { DEV: true }, want: false },
    { name: 'DEV, флаг false', env: { DEV: true, VITE_ENABLE_MOCKS: 'false' }, want: false },
    { name: 'DEV, флаг не "true"', env: { DEV: true, VITE_ENABLE_MOCKS: '1' }, want: false },
    { name: 'prod с флагом', env: { DEV: false, VITE_ENABLE_MOCKS: 'true' }, want: false },
    { name: 'DEV не задан, флаг true', env: { VITE_ENABLE_MOCKS: 'true' }, want: false },
    { name: 'пустое окружение', env: {}, want: false },
  ]
  for (const c of cases) it(c.name, () => { expect(shouldEnableMocks(c.env)).toBe(c.want) })
})
