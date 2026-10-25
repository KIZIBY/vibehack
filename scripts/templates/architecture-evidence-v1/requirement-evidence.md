# Requirement evidence v1

- Schema: requirement-evidence-v1
- Checkpoint-C: {{CHECKPOINT_C}}
- Implementation-Root: {{IMPLEMENTATION_ROOT}}
- Verdict: PASS

## Requirement map

| requirement | mode | primary-test | green-run | adjacent-test | adjacent-run | evidence | retest |
|---|---|---|---|---|---|---|---|
| FR-001 | execution | T-EXAMPLE-001 | {{GREEN_RUN_64HEX}} | T-EXAMPLE-ADJ-001 | {{ADJACENT_RUN_64HEX}} | process-receipt-v1 | passed |
| NFR-001 | inspection | T-PORTABLE-001 | - | - | - | checkpoint-file={{INSPECTION_PATH}};sha256={{INSPECTION_SHA256_64HEX}} | reviewed |
