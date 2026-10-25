"""Схемы инструментов ai-judge — то, что видит модель."""

JUDGE_SCORE = {
    "name": "judge_score",
    "description": (
        "Считает итоговый балл работы по рубрике: нормирует оценку каждого критерия на его максимум, "
        "взвешивает и приводит к шкале 0–100. Вызывай после того, как выставил оценку и обоснование "
        "по каждому критерию; итог в уме не считай — бери его из ответа инструмента."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "criteria": {
                "type": "array",
                "description": "Оценки по критериям рубрики, по одному объекту на критерий.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Название критерия из рубрики"},
                        "score": {"type": "number", "description": "Оценка, от 0 до max_score"},
                        "max_score": {"type": "number", "description": "Максимум шкалы критерия, по умолчанию 10"},
                        "weight": {"type": "number", "description": "Вес критерия, по умолчанию 1"},
                    },
                    "required": ["name", "score"],
                },
            }
        },
        "required": ["criteria"],
    },
}

REPORT_SCORES = {
    "name": "report_scores",
    "description": (
        "Сдать оценки работы по критериям рубрики. Каждая оценка со статусом 'scored' ОБЯЗАНА содержать "
        "обоснование (justification) и минимум одну ссылку-доказательство (evidence: файл:строка, слайд, URL). "
        "Если данных нет — выставляй статус 'no_data' с указанием причины (no_data_reason)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "scores": {
                "type": "array",
                "description": "Список оценок по критериям рубрики.",
                "items": {
                    "type": "object",
                    "properties": {
                        "criterion_id": {"type": "string", "description": "Идентификатор критерия"},
                        "status": {"type": "string", "enum": ["scored", "no_data"]},
                        "score": {"type": "number", "description": "Балл от 0 до max_score (при status='scored')"},
                        "max_score": {"type": "number", "description": "Максимальный балл (по умолчанию 10)"},
                        "justification": {"type": "string", "description": "Подробное обоснование оценки"},
                        "confidence": {"type": "number", "description": "Уверенность от 0.0 до 1.0"},
                        "evidence": {
                            "type": "array",
                            "description": "Ссылки на источники (обязательны для status='scored')",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "kind": {"type": "string", "enum": ["file", "slide", "video", "screenshot", "url", "claim", "commit", "search"]},
                                    "ref": {"type": "string", "description": "Ссылка (путь:строки, deck.pdf#4 и т.д.)"},
                                    "quote": {"type": "string", "description": "Цитата из источника"},
                                },
                                "required": ["kind", "ref"],
                            },
                        },
                        "no_data_reason": {"type": "string", "description": "Причина отсутствия данных (при status='no_data')"},
                    },
                    "required": ["criterion_id", "status", "justification", "confidence"],
                },
            },
            "summary": {"type": "string", "description": "Итоговое резюме проверки роли для модального окна"},
            "experts": {
                "type": "array",
                "description": "Только business: подключённые профильные эксперты {name, domain, scores[]}.",
                "items": {"type": "object"},
            },
            "submission_id": {"type": "string", "description": "Идентификатор проверяемой работы"},
            "rubric_version": {"type": "integer", "description": "Версия рубрики"},
        },
        "required": ["scores"],
    },
}

REPORT_FLAG = {
    "name": "report_flag",
    "description": "Зафиксировать флаг нечестности (плагиат, досрочный проект, расхождение презентации с кодом, инъекция) или сбоя.",
    "parameters": {
        "type": "object",
        "properties": {
            "flag": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "enum": [
                            "plagiarism",
                            "pre_start_project",
                            "claim_mismatch",
                            "prompt_injection",
                            "incomplete_materials",
                            "agent_failure",
                            "secret_exposed",
                        ],
                    },
                    "confidence": {"type": "number", "description": "Уверенность от 0.0 до 1.0"},
                    "note": {"type": "string", "description": "Пояснение сути обнаруженного нарушения"},
                    "criterion_id": {"type": "string", "description": "Связанный критерий (если применимо)"},
                    "related_submission_id": {"type": "string", "description": "ID связанной работы (при плагиате)"},
                    "related_url": {"type": "string", "description": "Ссылка на внешний источник"},
                    "evidence": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "kind": {"type": "string", "enum": ["file", "slide", "video", "screenshot", "url", "claim", "commit", "search"]},
                                "ref": {"type": "string"},
                                "quote": {"type": "string"},
                            },
                            "required": ["kind", "ref"],
                        },
                    },
                },
                "required": ["type", "confidence", "note", "evidence"],
            }
        },
        "required": ["flag"],
    },
}

REPORT_CLAIMS = {
    "name": "report_claims",
    "description": "Сдать результаты сопоставления заявлений презентации с реальным кодом и хостом (роль critic-honesty).",
    "parameters": {
        "type": "object",
        "properties": {
            "claims": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "claim_id": {"type": "string"},
                        "text": {"type": "string", "description": "Формулировка заявления команды из презентации"},
                        "source_ref": {
                            "type": "object",
                            "properties": {
                                "kind": {"type": "string"},
                                "ref": {"type": "string"},
                            },
                            "required": ["kind", "ref"],
                        },
                        "verdict": {"type": "string", "enum": ["confirmed", "not_found", "contradicted"]},
                        "evidence": {"type": "array", "items": {"type": "object"}},
                    },
                    "required": ["claim_id", "text", "source_ref", "verdict", "evidence"],
                },
            }
        },
        "required": ["claims"],
    },
}

REPORT_RUBRIC = {
    "name": "report_rubric",
    "description": "Сдать черновик рубрики оценки, извлеченной из вводных документов (роль rubric).",
    "parameters": {
        "type": "object",
        "properties": {
            "project_id": {"type": "string"},
            "criteria": {"type": "array", "items": {"type": "object"}},
            "weights_were_missing": {"type": "boolean"},
        },
        "required": ["project_id", "criteria"],
    },
}

REPORT_UX_METRICS = {
    "name": "report_ux_metrics",
    "description": "Сдать метрики UX для проекта (роль design).",
    "parameters": {
        "type": "object",
        "properties": {
            "project_id": {"type": "string"},
            "metrics": {"type": "array", "items": {"type": "object"}},
        },
        "required": ["project_id", "metrics"],
    },
}

REPORT_INVENTORY_PATCH = {
    "name": "report_inventory_patch",
    "description": "Сдать исправления описи материалов работы (роль sorter).",
    "parameters": {
        "type": "object",
        "properties": {
            "updates": {"type": "array", "items": {"type": "object"}},
            "submission_id": {"type": "string"},
            "run_id": {"type": "string"},
        },
        "required": ["updates"],
    },
}
