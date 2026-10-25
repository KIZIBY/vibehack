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
