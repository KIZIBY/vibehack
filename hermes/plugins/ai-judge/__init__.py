"""ai-judge — плагин Hermes: детерминированный подсчёт балла по рубрике и журнал оценок."""
import json
import logging

from . import schemas, tools

log = logging.getLogger(__name__)


def _log_verdict(tool_name=None, args=None, result=None, **kwargs):
    """post_tool_call: каждую выставленную оценку — в лог шлюза (след для разбора спорных вердиктов)."""
    del kwargs
    if tool_name == schemas.JUDGE_SCORE["name"]:
        log.info("ai-judge verdict: args=%s result=%s", json.dumps(args, ensure_ascii=False, default=str), result)


def register(ctx):
    ctx.register_tool(
        name=schemas.JUDGE_SCORE["name"],
        toolset="ai_judge",
        schema=schemas.JUDGE_SCORE,
        handler=tools.judge_score,
    )
    ctx.register_hook("post_tool_call", _log_verdict)
