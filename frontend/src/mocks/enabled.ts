/** Моки msw включаются только в dev и только явным VITE_ENABLE_MOCKS=true; по умолчанию фронтенд ходит в реальный backend. */
export function shouldEnableMocks(env: { DEV?: boolean; VITE_ENABLE_MOCKS?: string }): boolean {
  return env.DEV === true && env.VITE_ENABLE_MOCKS === 'true'
}
