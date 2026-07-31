---
name: slack-release-announcement
description: Use when the user asks for a Slack message, announcement, or "mensaje de update" about one or more released CLI versions (e.g. "mensaje para slack de la 2.10.0", "anuncia el release", "post de la nueva version").
---

# Slack Release Announcement

Turns one or more `cli/CHANGELOG.md` entries into a short Spanish Slack announcement
the user copies by hand into Slack.

## Source of truth

Read `cli/CHANGELOG.md` and use ONLY what the requested versions list. Never invent
skills, flags, commands or version numbers. If a version isn't in the changelog, say so
and stop.

## Output contract

Plain text, Spanish, in this order:

1. **Título** — one line: product + versions + `🚀`.
2. **Novedades** — one section per group of `Added` entries. One bullet per item:
   `Nombre (alias): qué hace, en media línea`.
3. **Cambios / refactors** — only for `Changed` or `Removed` entries that alter how
   people use the tool. Say what changed and what to use instead. Prefix removed flags
   or breaking bits with `⚠️`.
4. **Mejoras y fixes** — ONE generic sentence covering every `Fixed` entry together.
   Never enumerate individual fixes, no matter how interesting they are.
5. **Cierre** — the command to update, e.g. `Para actualizar: somnio update`.

Group multiple versions by theme (new skills / new commands / refactor), not by version
number — the reader cares about what changed, not which release it landed in.

## Style

- **Español rioplatense**, informal but professional (`elegís`, `usá`, `tenés`).
- **One line per bullet.** If a bullet needs a second sentence, it's too long — cut it.
  Changelog entries are 3–5 lines; the bullet is ~10 words.
- **Emojis: one per section header, plus `⚠️` for breaking changes.** Never inside a bullet.
- **No Markdown syntax in the text** — no `*`, `_`, `` ` ``, `#`. The user pastes into
  Slack and applies formatting there. Bold section headers and command names by rendering
  them bold, not by typing asterisks.
- Command and alias names go bare: `somnio skills update`, not quoted or backticked.

## Example (2.9.0 + 2.10.0)

> Somnio CLI 2.9.0 y 2.10.0 ya están disponibles 🚀
>
> 🆕 **Nuevas skills (2.9.0)**
>
> - **Angular (2+)**: health audit (ah) y best practices (ap)
> - **Harness Audit (ha)**: puntúa qué tan completo está el harness de IA del proyecto
> - **SOC 2 Readiness (s2)**: evidencia contra los Trust Services Criteria
>
> 🧹 **Nuevo grupo de comandos somnio skills (2.10.0)**
>
> Las skills ahora tienen su propio ciclo de vida, separado del binario:
>
> - **somnio skills install**: elegís qué skills y dónde, global o por proyecto
> - **somnio skills update**: actualiza solo las que ya tenés instaladas
>
> 🔄 **Refactor de somnio update**
>
> Ahora solo actualiza el CLI. Ya no borra ni reinstala todas las skills en todos los
> agentes. Para eso usá somnio skills update.
> ⚠️ Se eliminaron los flags --legacy, --all-skills y --post-update.
>
> 🛠️ **Mejoras y fixes**
>
> Varias mejoras y correcciones en la instalación de skills y en la experiencia
> interactiva del CLI.
>
> Para actualizar: **somnio update**

## Common mistakes

| Mistake | Fix |
|---|---|
| Copying the changelog's technical detail into the bullet | Keep the outcome, drop the mechanism |
| Listing each `Fixed` entry | One generic sentence for all of them |
| Emoji on every bullet | Section headers only |
| Writing `*negrita*` / backticks | Plain text; the user formats in Slack |
| Splitting the message by version | Group by theme, mention the version in the header |
