---
description: "Create or update the project constitution with core development principles. Usage: /speckit.constitution [principles]"
handoffs:
  - label: Build Specification
    agent: speckit.specify
    prompt: Implement the feature specification based on the updated constitution.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

Manage the project constitution at `docs/constitution.md`. This file defines non-negotiable development principles.

1. **Load the constitution.** `docs/constitution.md` поставляется вместе с харнессом: 17 универсальных
   инвариантов I-1…I-17 (Часть I), доменные каноны (Часть II), процедура поправок и журнал
   (Часть III) и доменные слоты `[ЗАПОЛНИ]`. Точный список, версия и формулировки — только из
   самого файла, не из памяти. Файла нет → это повреждённая установка: остановись с
   `BLOCKED: constitution-missing` и сообщи владельцу; устав с нуля не генерируй.

2. **Правь существующий устав, не регенерируй его:**
   - заполняй слоты `[ЗАПОЛНИ]` фактами проекта — из user input, `PROJECT.md` (стек, окружения,
     модель входа, доменные правила §9) и ответов владельца; неизвестное → вопрос владельцу, а не
     правдоподобная догадка;
   - уточняй применимость инварианта к проекту (например I-5 — для одно- или многопользовательского
     продукта) явной формулировкой, а не удалением;
   - доменные правила продукта добавляй в Часть II как подчинённые конкретизации инвариантов;
   - универсальные инварианты не удаляй и не перенумеровывай; ослабление, отмена или новый
     инвариант — только поправкой по процедуре Части III с явным решением владельца.

   При любой правке соблюдай процедуру поправок: изменение + bump версии + запись в журнал;
   молчаливый обход запрещён. Сверка enforcement — `docs/constitution-check.md`.

3. **Collect/derive values** from user input, `PROJECT.md` or existing docs.

4. **Validate**: No vague language, all principles testable, MUST/SHOULD explicit. Конвенция,
   которая действительно важна, получает исполняемую проверку — hook, линт или тест (I-17), либо
   явно помечается как advisory.

5. **Write** to `docs/constitution.md`.

6. **Report**: version, изменённые инварианты и слоты, оставшиеся `[ЗАПОЛНИ]`, suggested next command.
