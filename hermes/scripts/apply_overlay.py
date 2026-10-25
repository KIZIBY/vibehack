"""Накладывает обвес на данные Hermes: сливает config.yaml и кладёт SOUL.md.

Запускается внутри контейнера Hermes (там ruamel.yaml — им же Hermes читает конфиг), см. deploy.sh:
    python3 apply_overlay.py <overlay_dir> <hermes_home>
"""
import io
import os
import shutil
import sys
from pathlib import Path


def merge(base, overlay):
    """Накладывает overlay на base на месте. Словари — рекурсивно, списки — объединение с сохранением
    порядка, иначе побеждает overlay. Мутирует base (так у ruamel сохраняются комментарии)."""
    if isinstance(base, dict) and isinstance(overlay, dict):
        for key, value in overlay.items():
            base[key] = merge(base[key], value) if key in base else value
        return base
    if isinstance(base, list) and isinstance(overlay, list):
        base.extend([item for item in overlay if item not in base])
        return base
    return overlay


def _same_owner_as(path, ref):
    """Контейнер запускается root'ом в обход entrypoint — отдаём файл владельцу каталога данных."""
    st = ref.stat()
    try:
        os.chown(path, st.st_uid, st.st_gid)
    except PermissionError:
        pass


def main(overlay_dir, hermes_home):
    from ruamel.yaml import YAML

    yaml = YAML()  # round-trip: комментарии и порядок ключей серверного конфига сохраняются
    overlay_dir, hermes_home = Path(overlay_dir), Path(hermes_home)
    config_path = hermes_home / "config.yaml"

    before = config_path.read_text() if config_path.exists() else ""
    current = yaml.load(before) if before.strip() else None
    merged = merge(current if current is not None else {}, yaml.load((overlay_dir / "config.yaml").read_text()) or {})
    out = io.StringIO()
    yaml.dump(merged, out)
    if out.getvalue() != before:
        if config_path.exists():
            backup = config_path.with_name("config.yaml.bak")
            shutil.copy2(config_path, backup)
            _same_owner_as(backup, hermes_home)
        config_path.write_text(out.getvalue())
        _same_owner_as(config_path, hermes_home)
        print(f"apply_overlay: {config_path} обновлён (прежний — config.yaml.bak)")
    else:
        print(f"apply_overlay: {config_path} без изменений")

    soul = hermes_home / "SOUL.md"
    shutil.copyfile(overlay_dir / "SOUL.md", soul)
    _same_owner_as(soul, hermes_home)
    print(f"apply_overlay: {soul} обновлён")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: apply_overlay.py <overlay_dir> <hermes_home>")
    main(sys.argv[1], sys.argv[2])
