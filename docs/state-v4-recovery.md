# State V4: read-only recovery

`scripts/pipeline-state-recover-v4.sh` — стабильная поверхность инспекции на случай, когда
канонический writer состояния (`scripts/pipeline-state.sh`) временно недоступен (например, сломан
частичным обновлением). В ней нет ни одного пути мутации, лока или pair-WAL; и она, и
`scripts/pipeline-state.sh` используют `scripts/lib/pipeline-state-reader-v4.pl` как единственный
источник истины о форме state.

```bash
bash scripts/pipeline-state-recover-v4.sh validate-state specs/NNN-slug
bash scripts/pipeline-state-recover-v4.sh status specs/NNN-slug
```

Recovery-поверхность descriptor-валидирует и `state.md`, и точную append-only таблицу `audit.md`,
но не владеет ни writer-локом, ни pair-WAL reconciliation. Поэтому текущий V4 честно
отображается как `profile=v4-current authority=unverified`; отсутствующие, битые, symlink- или
конкурентно подменённые байты audit — fail closed. Для читаемых V1/V2/V3 выводится
`authority=migration-required` и точный путь вперёд:

```text
bash scripts/pipeline-state.sh migrate-v4 <SPEC_DIR>
```

Recovery CLI эту команду никогда не выполняет. Миграция возобновляется только после
восстановления канонического writer'а, потому что только он владеет per-spec локом и атомарным
pair-WAL state/audit. Legacy-опции init, переключателя «отключить writer» через окружение или
скопированной реализации миграции нет. Неизвестные delivery-профили и битый state остаются
fail-closed.

Покрытие: `tests/harness/cases/state-recover.sh` (tier `fast`).
