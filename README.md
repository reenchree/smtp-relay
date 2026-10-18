# smtp-relay

A small in-cluster SMTP server that forwards mail to Amazon SES with the SES v2 `SendEmail` API (raw content). Apps send plain SMTP. The relay signs SES calls with whatever the AWS default credential chain finds; in the clusters that is IRSA web identity, so there are no long-lived keys.

## Behaviour

- Accepts connections only from `ALLOWED_CIDRS`; anyone else gets `421`.
- `MAIL FROM` must be `@ALLOWED_FROM_DOMAIN`, else `550`. A null sender also gets `550`.
- At most `MAX_RECIPIENTS` recipients (SES max 50); the next one gets `452`.
- Messages over `MAX_BYTES` get `552`, and SES is never called.
- Returns **`250` only after SES returns a MessageId.**
  - Throttling, SES 5xx, network errors, missing credentials and anything unexpected → `451`, so the client retries.
  - `MessageRejected`, `MailFromDomainNotVerified`, `BadRequest`, `AccountSuspended`, `NotFound` and `AccessDenied` → `554`.
- No AUTH and no STARTTLS: it is meant for a ClusterIP Service.
- Logs one line per message: from, recipient count, size, MessageId or error code. It never logs bodies.
- `:9090/healthz` and `:9090/metrics` (`smtp_relay_messages_total{result="sent|ses_retryable|ses_permanent|rejected"}`).

## Configuration

| Env | Default | |
|---|---|---|
| `ALLOWED_FROM_DOMAIN` | (required) | e.g. `reenchree.dev` |
| `ALLOWED_CIDRS` | `10.42.0.0/16` | comma/space separated |
| `MAX_BYTES` | `10485760` | |
| `MAX_RECIPIENTS` | `50` | |
| `MAX_PROCESSINGS` | `16` | concurrent SMTP sessions |
| `LISTEN_HOST` / `LISTEN_PORT` | `0.0.0.0` / `2525` | |
| `METRICS_PORT` | `9090` | |
| `AWS_REGION` | `us-west-2` | plus the usual SDK env (`AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, …) |
| `LOG_LEVEL` | `info` | |

IAM: `ses:SendEmail` and `ses:SendRawEmail` on the sending identity, ideally with a `ses:FromAddress` condition.

## Development

There is no host Ruby needed; everything runs in docker:

```sh
printf 'FROM ruby:3.4.11-alpine3.24\nRUN apk add --no-cache build-base\n' | docker build -t smtp-relay-dev -
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e BUNDLE_PATH=/src/.bundle-cache \
  -v "$PWD":/src -w /src smtp-relay-dev sh -c 'bundle install && bundle exec rake test'

docker build -t smtp-relay:local . && test/smoke.sh smtp-relay:local
```

- `test/relay_test.rb` (unit) runs the real server against a stubbed SES client.
- `test/smoke.sh` (container) runs the built image read-only as uid 65534 against `test/fake_ses.rb`.

## Images

CI (`.github/workflows/ci.yml`) runs unit tests, then the smoke test on amd64 and arm64. Only on `main`, it then pushes an arm64 image to private ECR, as `051946164308.dkr.ecr.us-west-2.amazonaws.com/smtp-relay:{0.1.<run>,sha-<sha>,latest}` via `GitHubOIDCECRPushRole`. Each push gets a build-provenance attestation stored in GitHub:

```sh
gh attestation verify oci://051946164308.dkr.ecr.us-west-2.amazonaws.com/smtp-relay@sha256:<digest> -R reenchree/smtp-relay
```

(This needs `aws ecr get-login-password | docker login …` first.) Clusters pull with an `ecr-creds` Secret minted by External Secrets Operator (`ECRAuthorizationToken`, IRSA role `*-k8s-ecr-pull`).
