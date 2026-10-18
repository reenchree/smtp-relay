# CLAUDE.md

## What this is

`smtp-relay`: plain SMTP in, SES v2 `SendEmail` (raw) out. It replaces the postfix + SES-SMTP-key relay in both clusters so that no long-lived AWS key is needed; it runs on IRSA. Ruby 3.4, `midi-smtp-server` + `aws-sdk-sesv2` + `webrick`. See README for behaviour and config.

## Deployments

| Cluster | Manifests | Namespace / SA | IRSA role |
|---|---|---|---|
| sea-k3s | `../sea-k8s-flux/infra/smtp-relay/` | `mail` / `smtp-relay` | `sea-k8s-smtp-relay` |
| blr-k3s | `../blr-k8s-flux/infra/smtp-relay/` | `monitoring` / `smtp-relay` | `blr-k8s-smtp-relay` |

Roles live in `../terraform-core/` (`k8s_irsa.tf`, `blr_k8s_irsa.tf`). The policy is SendEmail/SendRawEmail on `identity/reenchree.dev` with `ses:FromAddress *@reenchree.dev`. Consumers keep using Service `smtp-relay` port 25, which maps to container port 2525.

## midi-smtp-server gotchas (verified against 3.3.2 source)

- `on_mail_from_event`/`on_rcpt_to_event` receive the raw `<addr> PARAMS`. The return value becomes the envelope, so always return the bare address.
- **Never raise in `on_message_data_receiving_event`.** The session stays in DATA mode and desyncs: repeated 552s, and the mail can still be sent. Flag it and clear the buffer, then raise in `on_message_data_event`.
- Raising in `on_connect_event` always produces `421`, whatever exception class is used.
- Any non-Smtpd exception from `on_message_data_event` becomes `451` (midi default). Never return without a MessageId.
- Don't name a test helper `message`: it shadows `Minitest::Assertions#message`.

## Rules

- **Never return 250 unless SES returned a MessageId.** Tests enforce it, and mutation-checked.
- Never log message bodies; the smoke test greps for this.
- The image runs read-only as uid 65534; keep it that way (no tmp writes, no bootsnap).
- CI publishes only from `main`, after unit tests and the amd64+arm64 smoke pass. Actions and the base image are pinned by SHA/digest; Dependabot bumps them.
- Images: private ECR `smtp-relay`, **arm64-only**, because ECR's lifecycle rule expires untagged images and that would include multi-arch children. Tags are `0.1.<run_number>` (gappy, since PR runs consume numbers too). Flux pins `:<tag>@sha256:<digest>`; bump by hand, as Renovate skips ECR. Renaming `ci.yml` resets `run_number`; bump the minor (`0.2.`) if that happens.
- Push trust: this repo uses GitHub's immutable OIDC subject, trusted explicitly on `main` in terraform-core `iam_github.tf`.
- Pull: the External Secrets `ECRAuthorizationToken` generator with SA `ecr-pull` (annotation `eks.amazonaws.com/role-arn` → `sea-k8s-ecr-pull` / `blr-k8s-ecr-pull`) feeds Secret `ecr-creds`.
