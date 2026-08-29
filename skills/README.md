# Skills

Agent skills used by the people who maintain this repository. These are **not** shipped to
customers — they are tooling for release work.

| Skill | Run by | Purpose |
|---|---|---|
| [`author-upgrade-skill`](author-upgrade-skill/) | Release engineer, after cutting a tag | Generate the customer-facing upgrade guide for a dataplane release |

## Running one

Point a coding agent at the skill's `SKILL.md` from the repository root:

> Follow `skills/author-upgrade-skill/SKILL.md` for the `2026.8.4` release.

The scripts under `assets/` are also runnable directly — see each skill's `SKILL.md`.

## Agent auto-discovery

`.claude/` is gitignored in this repository, so these live under `skills/` to stay in
version control. If you want your agent to discover them automatically, symlink locally
(the symlink itself is ignored):

```bash
mkdir -p .claude/skills
ln -s ../../skills/author-upgrade-skill .claude/skills/author-upgrade-skill
```

## Before running anything that produces customer-facing output

`author-upgrade-skill` writes into `charts/`, which is public. Its disclosure scan needs
two lists that are deliberately not committed — a list of self-managed customers is
exactly the kind of thing the scan exists to keep out of this repository.

```bash
export UNION_ORG_SLUGS='org-one|org-two|org-three'
export UNION_INTERNAL_PATHS='service-one|service-two'
```

Or create `skills/author-upgrade-skill/assets/.disclosure-orgs` and `.disclosure-paths`
(one entry per line). Both filenames are gitignored. The scan warns loudly when a list is
missing, because without one it is materially weaker.
