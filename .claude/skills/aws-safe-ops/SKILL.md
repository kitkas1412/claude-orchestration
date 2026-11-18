---
name: aws-safe-ops
description: Inspect AWS EC2 and S3 state and prepare commands safely through the `claude-agent` SSO profile. Use when the brief carries MODE INSPECT or PREPARE with AWS-REGION, or asks for live AWS state, AWS CLI drafts or EC2 dry-runs. Keywords - aws, ec2, s3, sso, dry-run, describe-instances.
---

# AWS safe operations

Read by aws-engineer. `hooks/aws-agent-bash.sh` (per agent) and `hooks/guard-aws.sh` (global) enforce the command grammar; this skill is the rulebook behind them. The profile has `PowerUserAccess` and there is no IAM read-only layer, so the hooks are defense in depth, not a boundary.

## When to use

- The brief has `MODE: INSPECT` or `MODE: PREPARE`, `AWS-REGION`, and `AWS-ACCOUNT: <id>|unset`.
- Skip when the profile `claude-agent` does not exist or the token is expired: report BLOCKED.

## Procedure

One-time setup by the user (the agent never reads `~/.aws`). In `~/.aws/config`:

```ini
[profile claude-agent]
sso_session = <name>
sso_account_id = <ACCOUNT_ID>
sso_role_name = PowerUserAccess
region = <region>
output = json

[sso-session <name>]
sso_start_url = https://<org>.awsapps.com/start
sso_region = <region>
sso_registration_scopes = sso:account:access
```

The user runs `aws sso login --profile claude-agent` before the session and `aws sso logout` after it. The agent never logs in.

1. Preflight: `aws sts get-caller-identity --profile claude-agent --output json`. Expired token: BLOCKED, ask for `! aws sso login --profile claude-agent`. Wrong account: BLOCKED. Role ARN without `AWSReservedSSO_PowerUserAccess`: warn.
2. Canonical order: `aws --profile claude-agent --region R <svc> <op> ...`. The profile appears exactly once on every call.
3. Allowed: `sts get-caller-identity`; `ec2 describe-*` (not the secret-bearing ones); `s3 ls`; `s3api list-*`, `head-bucket`, `get-bucket-*` (location, versioning, encryption, policy, policy-status, acl, tagging, lifecycle-configuration, cors, logging, ownership-controls, website, notification-configuration, replication) and `get-public-access-block`; `--version`; `help` only as `aws help`, `aws <svc> help` or `aws <svc> <op> help` for `sts`, `ec2`, `s3` and `s3api` (allowlisted operations; not `s3 <op> help`). EC2 mutating verbs pass only with the exact flag `--dry-run`; abbreviated flags (`--prof`, `--dry`, `--no-d`, `--de`) are denied.
4. Denied: `configure`, `sso`, login and logout, other `sts`; secret reads (`ssm get-parameter*`, `secretsmanager get-secret-value`, `lambda get-function*` and `list-functions`, `ecs describe-task-definition`, `cloudformation describe-stacks` and `get-template`, `ec2 get-*`, userData, `describe-vpn-connections`); `s3 cp|sync|mv|presign|rm|rb`, `s3api get-object`; the flags `--debug`, `--endpoint-url`, `--cli-input-json`, `--cli-input-yaml` and `file://`; SDK inline scripts; aws behind wrappers or runners (`env`, `xargs`, `bash -c`, `uv run`, `npx`, ...); IaC deploy verbs (`cdk`, `sam`, `serverless` ... `deploy`). `AWS_*` is denied as an assignment or env prefix, through `export`, `declare`, `typeset`, `local`, `readonly`, `read`, `mapfile` or `printf -v`, and anywhere on a line that runs aws, a wrapper or runner, a shell, `eval` or `source`.
5. The agent's Bash allows only `aws jq grep head tail wc cut tr sort uniq echo date`, each with a short option allowlist (no `jq -f`, `--rawfile`, `env`/`$ENV`, `input`; no `grep -r`/`-f`; no `tail -f`; no `sort -o`/long options). Filter with `--query` or a pipe to `jq`. The agent has no Edit or Write tool, so results and drafts go inline in the report.
6. Command shape: literal IDs only, no `$VAR`; put `--query`, `--filters` and jq filters in single quotes; the only operators are `|`, `&&` and `;`. Outside single quotes only letters, digits and `_ . / : = , @ % + -` are allowed, so double quotes, `$`, globs, braces, `~`, `#`, redirection, `( )` and backslashes are blocked. No absolute, `~`, `..` or credential paths (`.aws`, `.ssh`, `.env`, ...).

INSPECT recipes: narrow with `--query` and `--output json`, add `--max-items` on big lists, then summarize; narrow long output further (`--max-items`, `head`) instead of pasting it.

PREPARE recipes: draft the command or IaC inline in the report, in fenced blocks. Repo IaC files are written by `devops-engineer`, not by this agent. For EC2 run the same call with `--dry-run`: `DryRunOperation` means permitted, `UnauthorizedOperation` means denied. Nothing was changed either way. S3 has no dry-run, so mark S3 drafts unvalidated.

Handoff: every mutating command goes under COMMANDS FOR USER as `! aws ... --profile claude-agent`, with its effect and a rollback. The user runs it.

## Checklist

- [ ] Preflight done; identity and account match the brief; ID masked as `1234****9012`.
- [ ] Every call has `--profile claude-agent` once and `--region`.
- [ ] No mutation run; each is a `!` handoff with effect and rollback.
- [ ] EC2 drafts dry-run validated; S3 drafts marked unvalidated.
- [ ] No secret-looking output echoed; hook blocks reported by category.

## Examples

```bash
aws --profile claude-agent --region eu-west-1 ec2 describe-instances --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,type:InstanceType}' --output json
aws --profile claude-agent --region eu-west-1 s3 ls
aws --profile claude-agent --region eu-west-1 s3api get-bucket-policy --bucket <bucket>
aws --profile claude-agent --region eu-west-1 ec2 run-instances --image-id <ami> --instance-type t3.micro --dry-run
```

Handoff block:

```
COMMANDS FOR USER
! aws --profile claude-agent --region eu-west-1 ec2 stop-instances --instance-ids <id>
  Effect: stops <id>; the instance stays and keeps its EBS volume.
  Rollback: ! aws --profile claude-agent --region eu-west-1 ec2 start-instances --instance-ids <id>
```

## Anti-patterns

- SDK scripts (boto3, node) or inline interpreters to get around the CLI allowlist.
- `--debug`, `--endpoint-url`, `file://` or `--cli-input-*`.
- Retrying, rewording or splitting a command after a hook block.
- Running `aws sso login` or `aws configure`, or reading `~/.aws`.
- `s3 cp` or `s3api get-object` of content; listing only.
- Printing an unmasked account ID or secret-looking values.

## Residual risks

- Other agents' scripts run as the same OS user and can use the cached SSO session; `guard-aws.sh` only covers the `aws` CLI text it sees.
- The real boundary is a read-only permission set; `PowerUserAccess` is not one. Run `aws sso logout` when done.

---
Version 1.0.0. Last reviewed 2026-11-18.
