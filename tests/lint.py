#!/usr/bin/env python3
"""Lints agents and skills in this repository. Requires ruby for YAML parsing. Usage: python3 tests/lint.py"""
import json, os, re, subprocess, sys

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser('~')
TOOLS = {'Agent', 'Read', 'Grep', 'Glob', 'Edit', 'Write', 'Bash', 'WebSearch', 'WebFetch', 'AskUserQuestion', 'SendMessage', 'EnterWorktree', 'ExitWorktree'}
WORKTREE_TOOLS = {'EnterWorktree', 'ExitWorktree'}
MODELS = {'haiku', 'sonnet', 'opus'}
EFFORTS = {'low', 'medium', 'high', 'xhigh', 'max'}
errors, warnings = [], []


def parse(path):
    text = open(path, encoding='utf-8').read()
    m = re.match(r'^---\n(.*?)\n---\n?(.*)$', text, re.S)
    if not m:
        errors.append('%s: no frontmatter' % path)
        return None, text
    ruby = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(STDIN.read))'
    r = subprocess.run(['ruby', '-e', ruby], input=m.group(1), capture_output=True, text=True)
    if r.returncode != 0:
        errors.append('%s: invalid YAML: %s' % (path, r.stderr.strip()[:160]))
        return None, m.group(2)
    return json.loads(r.stdout), m.group(2)


def skill_exists(name):
    return os.path.isfile('%s/skills/%s/SKILL.md' % (ROOT, name)) or os.path.isfile('%s/third_party/skills/%s/SKILL.md' % (ROOT, name))


agents = sorted(f for f in os.listdir(ROOT + '/agents') if f.endswith('.md'))
for f in agents:
    p = '%s/agents/%s' % (ROOT, f)
    d, body = parse(p)
    if d is None:
        continue
    if d.get('name') != f[:-3] or not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', str(d.get('name'))):
        errors.append('%s: bad name' % f)
    if d.get('model') not in MODELS:
        errors.append('%s: model must be pinned' % f)
    if 'effort' in d and d['effort'] not in EFFORTS:
        errors.append('%s: invalid effort %s' % (f, d['effort']))
    desc = d.get('description', '')
    if f != 'orchestrator.md' and not ('Use ' in desc and 'Does NOT' in desc):
        errors.append('%s: description lacks Use/Does NOT' % f)
    if len(desc) > 400:
        warnings.append('%s: long description (%d)' % (f, len(desc)))
    for t in [x.strip() for x in str(d.get('tools', '')).split(',')]:
        if t not in TOOLS:
            errors.append('%s: unknown tool %s' % (f, t))
        elif t in WORKTREE_TOOLS and f != 'orchestrator.md':
            errors.append('%s: %s is orchestrator-only' % (f, t))
    if f == 'orchestrator.md':
        have = [x.strip() for x in str(d.get('tools', '')).split(',')]
        for t in sorted(WORKTREE_TOOLS):
            if t not in have:
                errors.append('%s: missing tool %s' % (f, t))
    if f == 'release-manager.md' and 'WORKTREE-CHECK' not in body:
        errors.append('%s: missing WORKTREE-CHECK mode' % f)
    if f == 'release-manager.md':
        m = re.search(r"CONVENTIONAL_BRANCH_RE='([^']*)'", open(ROOT + '/hooks/git-publish.sh', encoding='utf-8').read())
        if not m or '`%s`' % m.group(1) not in body:
            errors.append('%s: branch regex differs from CONVENTIONAL_BRANCH_RE in hooks/git-publish.sh' % f)
    for s in d.get('skills') or []:
        if not skill_exists(s):
            errors.append('%s: missing skill %s' % (f, s))
    for ev in (d.get('hooks') or {}).values():
        for group in ev:
            for h in group.get('hooks', []):
                name = os.path.basename(h['command'])
                if not os.path.isfile('%s/hooks/%s' % (ROOT, name)):
                    errors.append('%s: missing hook %s' % (f, name))
    if f != 'orchestrator.md' and 'Final report' not in body:
        errors.append('%s: no output contract' % f)

skills = sorted(os.listdir(ROOT + '/skills'))
for s in skills:
    p = '%s/skills/%s/SKILL.md' % (ROOT, s)
    if not os.path.isfile(p):
        errors.append('%s: SKILL.md missing' % s)
        continue
    d, body = parse(p)
    if d is None:
        continue
    if d.get('name') != s or len(s) > 64 or not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', s):
        errors.append('%s: bad name' % s)
    if not 0 < len(d.get('description', '')) <= 1024:
        errors.append('%s: description length' % s)
    lines = len(body.splitlines())
    if lines >= 500:
        errors.append('%s: body too long (%d)' % (s, lines))
    if lines > 120:
        warnings.append('%s: over preload budget (%d lines)' % (s, lines))
    for section in ('## When to use', '## Procedure', '## Checklist', '## Examples', '## Anti-patterns'):
        if section not in body:
            errors.append('%s: missing section %s' % (s, section))
    if 'Last reviewed' not in body:
        errors.append('%s: no version note' % s)
    for ref in re.findall(r'~/\.claude/skills/([\w./-]+\.md)', body):
        if not os.path.isfile('%s/skills/%s' % (ROOT, ref)):
            errors.append('%s: broken reference %s' % (s, ref))

print('agents: %d, skills: %d' % (len(agents), len(skills)))
for w in warnings:
    print('WARN  ' + w)
for e in errors:
    print('ERROR ' + e)
print('RESULT: %d errors, %d warnings' % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
