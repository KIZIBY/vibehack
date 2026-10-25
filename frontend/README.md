# frontend/ — зона D

Веб-интерфейс: сайдбар проектов, чат, рубрика, решения, таблица оценок (React + Vite + Tailwind).
Задачи — `tasks.md` T080–T089, контракт — `contracts/openapi.yaml`.
Тесты: `bash scripts/test-unit.sh frontend` (vitest + Testing Library, `npm test`).

Данные — только из реального backend (`VITE_API_URL`, по умолчанию тот же origin). Моки msw
(`src/mocks/`) по умолчанию выключены; для работы без backend: `VITE_ENABLE_MOCKS=true npm run dev`.
