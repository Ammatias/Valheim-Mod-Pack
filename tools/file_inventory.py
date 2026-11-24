"""Render the downloadable archive inventory for a pack's repository page."""
from pathlib import Path
from urllib.parse import quote


def render_inventory(pack, manifest):
    files = sorted((item for package in manifest['packages'] for item in package['files']),
                   key=lambda item: item['path'].casefold())
    lines = [f'# Файлы {pack}', '', f"Версия: **{manifest['version']}**. Всего файлов: **{len(files)}**.", '',
             'Полный состав ZIP: пути относительно папки игры, размеры и SHA-256 каждого файла.', '',
             '[Установка и описание сборки](README.md) · [Машиночитаемый список](latest.json)', '']
    for package in manifest['packages']:
        name = package['url'].rsplit('/', 1)[-1]
        lines += [f"Архив: [{name}]({package['url']}) — {package['bytes']:,} байт.".replace(',', ' '), '',
                  f"SHA-256 архива: `{package['sha256']}`.", '']
    groups = [('Загрузчик BepInEx', lambda p: '/' not in p or p.startswith('BepInEx/core/')),
              ('Моды и их ресурсы', lambda p: p.startswith('BepInEx/plugins/')),
              ('Патчеры', lambda p: p.startswith('BepInEx/patchers/')),
              ('Начальные настройки', lambda p: p.startswith('BepInEx/config/'))]
    for title, belongs in groups:
        selected = [f for f in files if belongs(f['path'])]
        if not selected:
            continue
        lines += [f'## {title} ({len(selected)})', '',
                  '| Файл | Размер, байт | SHA-256 |', '|---|---:|---|']
        for item in selected:
            size = f"{item['bytes']:,}".replace(',', ' ')
            label = item['path'].replace('[', '\\[').replace(']', '\\]')
            lines.append(f"| [{label}]({quote(item['path'], safe='/')}) | {size} | `{item['sha256']}` |")
        lines.append('')
    return '\n'.join(lines)


def write_inventory(pack, manifest, destination):
    Path(destination).write_text(render_inventory(pack, manifest), encoding='utf-8')
