"""ai-judge — плагин Hermes: детерминированный подсчёт балла по рубрике и журнал оценок."""
import logging

from . import guard, journal, schemas, tools

log = logging.getLogger(__name__)


def register(ctx):
    # Инструмент подсчёта балла (judge_score)
    ctx.register_tool(
        name=schemas.JUDGE_SCORE["name"],
        toolset="ai_judge",
        schema=schemas.JUDGE_SCORE,
        handler=tools.judge_score,
    )
    # Инструменты отчётов ролей (FR-020)
    ctx.register_tool(
        name=schemas.REPORT_SCORES["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_SCORES,
        handler=tools.report_scores,
    )
    ctx.register_tool(
        name=schemas.REPORT_FLAG["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_FLAG,
        handler=tools.report_flag,
    )
    ctx.register_tool(
        name=schemas.REPORT_CLAIMS["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_CLAIMS,
        handler=tools.report_claims,
    )
    ctx.register_tool(
        name=schemas.REPORT_RUBRIC["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_RUBRIC,
        handler=tools.report_rubric,
    )
    ctx.register_tool(
        name=schemas.REPORT_UX_METRICS["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_UX_METRICS,
        handler=tools.report_ux_metrics,
    )
    ctx.register_tool(
        name=schemas.REPORT_INVENTORY_PATCH["name"],
        toolset="ai_judge",
        schema=schemas.REPORT_INVENTORY_PATCH,
        handler=tools.report_inventory_patch,
    )

    # Хуки
    ctx.register_hook("pre_tool_call", guard.pre_tool_call_guard)
    ctx.register_hook("post_tool_call", journal.post_tool_call)
    ctx.register_hook("post_llm_call", journal.post_llm_call)
