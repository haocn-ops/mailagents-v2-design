# Mailagents V2 Technical Design

## 1. Overview

This document defines a practical V2 design for the `haocn-ops/mailagents` project.

The V2 goal is not to add more isolated features. The goal is to turn the current V1 system into a service with clear boundaries, async reliability, and production-grade operability.

The design is based on review of the current repository:
- `README.md`
- `docs/development.md`
- `docs/openapi.yaml`
- `docs/openapi-admin.yaml`
- `docs/db/schema.sql`
- `docs/project-retrospective.md`
- `docs/current-production-state.md`
- `docs/redesign-architecture.md`
- `docs/redesign-schema.md`

## 2. Current System Summary

The current project is already more than a mailbox prototype. It is a control plane for programmable agent mailboxes with these working capabilities:
- SIWE authentication
- tenant and agent isolation
- mailbox allocation and release
- inbound message fetch
- OTP and verification link extraction
- webhook registration
- usage and invoice queries
- admin dashboard
- Mailu-backed real inbound and outbound mail

The main architectural issue in V1 is that too many concerns are mixed together:
- public API
- admin API
- internal API
- HTML UI rendering
- business rules
- storage access
- mail backend orchestration

In the current codebase this is most visible in `src/fetch-app.js`.

## 3. V2 Goals

V2 must preserve the existing product capabilities while fixing the main architectural problems.

Must keep:
- SIWE login
- tenant and agent model
- mailbox lifecycle
- inbound parsing
- webhook delivery
- billing visibility
- admin visibility
- real Mailu integration

Must improve:
- explicit service boundaries
- async job execution
- mailbox domain model
- message domain model
- outbound send lifecycle
- operational recovery
- observability

## 4. System Boundaries

V2 separates the system into four logical services.

### 4.1 Control Plane API

Owns:
- public API
- admin API
- internal API ingress
- auth and session issuance
- entitlement decisions
- billing read models
- operator-facing read models

Does not own:
- direct Maildir traversal
- SMTP protocol logic
- parser execution
- long-running mailbox jobs

### 4.2 Job Worker

Owns:
- mailbox provision and release
- credential reset
- outbound send submission
- webhook delivery
- reconciliation repair

### 4.3 Mail Sync Worker

Owns:
- inbound message discovery from Mailu or Maildir
- dedupe
- raw message persistence
- enqueueing parse jobs

### 4.4 Parser Worker

Owns:
- text extraction
- HTML normalization
- OTP extraction
- verification link extraction
- parser versioning
- historical reparse

Mailu remains the mail data plane. It is not the business API.

## 5. Deployment Topology

The preferred V2 deployment path is single-region Docker deployment with Redis added to the current production stack.

Components:
- `nginx`
- `control-plane-api`
- `job-worker`
- `mail-sync-worker`
- `parser-worker`
- `postgres`
- `redis`
- `mailu`

Cloudflare Worker should not shape the primary V2 architecture.

## 6. Repository Structure

The current `src/` layout should be evolved into the following structure:

```text
src/
  http/
    public/
      index.js
      auth-routes.js
      mailbox-routes.js
      message-routes.js
      webhook-routes.js
      billing-routes.js
    admin/
      index.js
      overview-routes.js
      tenant-routes.js
      mailbox-routes.js
      message-routes.js
      webhook-routes.js
      billing-routes.js
      risk-routes.js
      audit-routes.js
    internal/
      index.js
      inbound-routes.js
      mailbox-routes.js
      message-routes.js
  services/
    auth-service.js
    mailbox-service.js
    message-service.js
    send-service.js
    webhook-service.js
    billing-service.js
    entitlement-service.js
    admin-service.js
  repositories/
    postgres/
      mailbox-account-repo.js
      mailbox-lease-repo.js
      raw-message-repo.js
      message-repo.js
      parse-result-repo.js
      send-attempt-repo.js
      webhook-delivery-repo.js
    memory/
  jobs/
    index.js
    queue.js
    mailbox-provision-job.js
    mailbox-release-job.js
    message-ingest-job.js
    message-parse-job.js
    send-submit-job.js
    webhook-delivery-job.js
  workers/
    job-worker.js
    parser-worker.js
    mail-sync-worker.js
  read-models/
    tenant-mailbox-view.js
    tenant-message-view.js
    tenant-send-attempt-view.js
    admin-mailbox-health-view.js
  ui/
    admin/
    app/
```

Migration rule:
- do not keep adding business logic to `src/fetch-app.js`
- do not keep expanding monolithic store objects
- move new work into services, repositories, and jobs first

## 7. Domain Model

### 7.1 Mailbox Account

A real backend mailbox resource.

Fields:
- `id`
- `address`
- `domain`
- `backend_ref`
- `backend_status`
- `mailbox_type`
- `last_password_reset_at`
- `created_at`
- `updated_at`

Suggested states:
- `provisioning`
- `active`
- `disabled`
- `error`

### 7.2 Mailbox Lease

A product assignment of a mailbox account to a tenant and agent.

Fields:
- `id`
- `mailbox_account_id`
- `tenant_id`
- `agent_id`
- `lease_status`
- `purpose`
- `started_at`
- `ends_at`
- `released_at`
- `created_at`
- `updated_at`

Suggested states:
- `pending`
- `active`
- `releasing`
- `released`
- `expired`
- `frozen`

Constraint:
- at most one active or pending lease per mailbox account

### 7.3 Raw Message

A durable source reference for inbound message reparsing.

Fields:
- `id`
- `mailbox_account_id`
- `backend_message_id`
- `raw_ref`
- `headers_json`
- `sender`
- `sender_domain`
- `subject`
- `received_at`
- `ingested_at`

### 7.4 Message

A user-facing normalized message record.

Fields:
- `id`
- `raw_message_id`
- `tenant_id`
- `agent_id`
- `mailbox_account_id`
- `mailbox_lease_id`
- `from_address`
- `subject`
- `received_at`
- `message_status`
- `created_at`

Suggested states:
- `received`
- `parsed`
- `parse_failed`
- `archived`

### 7.5 Message Parse Result

A versioned parser output.

Fields:
- `id`
- `message_id`
- `parser_version`
- `parse_status`
- `otp_code`
- `verification_link`
- `text_excerpt`
- `confidence`
- `error_code`
- `created_at`

### 7.6 Send Attempt

A first-class outbound send lifecycle record.

Fields:
- `id`
- `tenant_id`
- `agent_id`
- `mailbox_account_id`
- `mailbox_lease_id`
- `from_address`
- `to_json`
- `cc_json`
- `bcc_json`
- `subject`
- `text_body_ref`
- `html_body_ref`
- `submission_status`
- `backend_queue_id`
- `smtp_response`
- `submitted_at`
- `created_at`
- `updated_at`

Suggested states:
- `queued`
- `submitting`
- `accepted`
- `failed`

### 7.7 Webhook Delivery

A delivery record separate from webhook definition state.

Fields:
- `id`
- `webhook_id`
- `event_type`
- `resource_id`
- `attempt_number`
- `delivery_status`
- `response_code`
- `response_excerpt`
- `delivered_at`
- `created_at`

## 8. Database Migration Plan

V2 should not replace the V1 schema in one step. It should add new tables and migrate gradually.

### 8.1 New Tables

Suggested first-wave tables:
- `mailbox_accounts`
- `mailbox_leases_v2`
- `raw_messages`
- `messages_v2`
- `message_parse_results`
- `send_attempts`
- `send_attempt_events`
- `webhook_deliveries`

### 8.2 Example SQL

```sql
create table mailbox_accounts (
  id uuid primary key default gen_random_uuid(),
  address text not null unique,
  domain text not null,
  backend_ref text,
  backend_status text not null default 'provisioning',
  mailbox_type text not null default 'pooled',
  last_password_reset_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table mailbox_leases_v2 (
  id uuid primary key default gen_random_uuid(),
  mailbox_account_id uuid not null references mailbox_accounts(id),
  tenant_id uuid not null references tenants(id),
  agent_id uuid not null references agents(id),
  lease_status text not null default 'pending',
  purpose text not null,
  started_at timestamptz,
  ends_at timestamptz not null,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index idx_mailbox_leases_v2_one_active
on mailbox_leases_v2(mailbox_account_id)
where lease_status in ('pending', 'active', 'releasing');
```

```sql
create table raw_messages (
  id uuid primary key default gen_random_uuid(),
  mailbox_account_id uuid not null references mailbox_accounts(id),
  backend_message_id text,
  raw_ref text,
  headers_json jsonb not null default '{}'::jsonb,
  sender text,
  sender_domain text,
  subject text,
  received_at timestamptz not null,
  ingested_at timestamptz not null default now()
);

create unique index idx_raw_messages_backend_unique
on raw_messages(mailbox_account_id, backend_message_id)
where backend_message_id is not null;
```

```sql
create table messages_v2 (
  id uuid primary key default gen_random_uuid(),
  raw_message_id uuid not null references raw_messages(id),
  tenant_id uuid not null references tenants(id),
  agent_id uuid references agents(id),
  mailbox_account_id uuid not null references mailbox_accounts(id),
  mailbox_lease_id uuid references mailbox_leases_v2(id),
  from_address text,
  subject text,
  received_at timestamptz not null,
  message_status text not null default 'received',
  created_at timestamptz not null default now()
);

create table message_parse_results (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references messages_v2(id),
  parser_version text not null,
  parse_status text not null,
  otp_code text,
  verification_link text,
  text_excerpt text,
  confidence numeric(5,4),
  error_code text,
  created_at timestamptz not null default now()
);
```

```sql
create table send_attempts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  agent_id uuid references agents(id),
  mailbox_account_id uuid not null references mailbox_accounts(id),
  mailbox_lease_id uuid references mailbox_leases_v2(id),
  from_address text not null,
  to_json jsonb not null,
  cc_json jsonb,
  bcc_json jsonb,
  subject text not null,
  text_body_ref text,
  html_body_ref text,
  submission_status text not null default 'queued',
  backend_queue_id text,
  smtp_response text,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table send_attempt_events (
  id uuid primary key default gen_random_uuid(),
  send_attempt_id uuid not null references send_attempts(id),
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
```

```sql
create table webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  webhook_id uuid not null references webhooks(id),
  event_type text not null,
  resource_id text not null,
  attempt_number int not null default 1,
  delivery_status text not null,
  response_code int,
  response_excerpt text,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);
```

### 8.3 Migration Steps

1. Add new tables.
2. Backfill `mailbox_accounts` from V1 `mailboxes`.
3. Backfill `mailbox_leases_v2` from V1 `mailbox_leases`.
4. Backfill message-related V2 tables from `messages` and `message_events`.
5. Move write paths to V2 tables.
6. Keep V1 read compatibility until V2 API is stable.

## 9. API Design

Create a new OpenAPI document as `docs/openapi-v2.yaml`.

Suggested public API surface:
- `POST /v2/auth/siwe/challenge`
- `POST /v2/auth/siwe/verify`
- `POST /v2/mailboxes/leases`
- `POST /v2/mailboxes/leases/{lease_id}/release`
- `GET /v2/mailboxes/accounts`
- `POST /v2/mailboxes/accounts/{account_id}/credentials/reset`
- `GET /v2/messages`
- `GET /v2/messages/{message_id}`
- `POST /v2/messages/send`
- `GET /v2/send-attempts`
- `GET /v2/send-attempts/{send_attempt_id}`
- `POST /v2/webhooks`
- `GET /v2/webhooks`
- `POST /v2/webhooks/{webhook_id}/rotate-secret`
- `GET /v2/usage/summary`
- `GET /v2/billing/invoices`
- `GET /v2/billing/invoices/{invoice_id}`

Important semantic changes:
- mailbox allocate becomes lease request
- send returns `send_attempt_id`, not only immediate SMTP acceptance semantics
- messages move from a single latest endpoint to list and detail endpoints

## 10. Read Models

V2 should expose read models rather than binding API responses directly to raw tables.

Suggested read models:
- `tenant_mailbox_view`
- `tenant_message_view`
- `tenant_send_attempt_view`
- `admin_mailbox_health_view`
- `admin_message_pipeline_view`

This keeps the API stable while underlying tables evolve.

## 11. Service Design

### 11.1 Mailbox Service

Responsibilities:
- validate tenant and agent ownership
- apply policy and TTL rules
- create mailbox leases
- enqueue provision and release jobs
- reset mailbox credentials

Suggested methods:
- `requestLease({ tenantId, agentId, purpose, ttlHours })`
- `releaseLease({ tenantId, leaseId })`
- `resetCredentials({ tenantId, accountId })`

### 11.2 Message Service

Responsibilities:
- list and fetch messages through read models
- ingest inbound message references
- create message records
- enqueue parse jobs

Suggested methods:
- `listMessages({ tenantId, mailboxId, cursor, limit })`
- `getMessage({ tenantId, messageId })`
- `ingestInboundMessage({ address, payload })`

### 11.3 Send Service

Responsibilities:
- validate mailbox ownership
- create send attempt records
- enqueue send jobs
- expose send status views

Suggested methods:
- `queueSend({ tenantId, agentId, mailboxId, to, subject, text, html })`
- `getSendAttempt({ tenantId, sendAttemptId })`
- `listSendAttempts({ tenantId, mailboxId })`

### 11.4 Entitlement Service

Responsibilities:
- evaluate free limits
- decide whether a request is allowed
- hide low-level payment proof details from product-facing flows

## 12. Job Design

Redis becomes mandatory for V2 because async work is a core part of the design.

Suggested job types:
- `mailbox.provision`
- `mailbox.release`
- `message.parse`
- `send.submit`
- `webhook.deliver`

Recommended payload identifiers:
- `request_id`
- `tenant_id`
- `agent_id`
- `mailbox_account_id`
- `mailbox_lease_id`
- `message_id`
- `send_attempt_id`

Retry policy:
- mailbox jobs: 3 attempts
- parser jobs: 3 attempts
- send submit jobs: 5 attempts
- webhook delivery jobs: 8 attempts with exponential backoff

## 13. Key Workflows

### 13.1 Mailbox Lease Request

1. API validates auth and entitlement.
2. Service creates lease in `pending`.
3. Service enqueues `mailbox.provision`.
4. API returns `lease_id` and pending state.
5. Worker provisions or reactivates backend mailbox account.
6. Worker marks lease as `active`.

### 13.2 Mailbox Release

1. API marks lease as `releasing`.
2. Service enqueues `mailbox.release`.
3. Worker disables or deletes backend mailbox.
4. Worker marks lease as `released`.

### 13.3 Inbound Message Pipeline

1. Mail sync worker receives backend event.
2. Worker writes `raw_messages`.
3. Worker creates user-facing `messages_v2`.
4. Worker enqueues parse job.
5. Parser worker writes `message_parse_results`.
6. Webhook delivery jobs are enqueued.

### 13.4 Outbound Send

1. API validates auth, ownership, and entitlement.
2. Service creates `send_attempts` in `queued`.
3. Service enqueues `send.submit`.
4. Worker submits through Mail backend gateway.
5. Worker records result and events.

## 14. Parser Design

The current parser implementation can be kept as an initial built-in parser, but V2 should treat parsing as a versioned pipeline.

Requirements:
- parser version is stored
- parse results are append-only
- reparsing historical messages is supported
- failures are recorded explicitly

Suggested first parser version:
- `builtin@1`

Suggested output fields:
- `otp_code`
- `verification_link`
- `text_excerpt`
- `parse_status`
- `confidence`

## 15. Mail Backend Gateway

The existing Mailu adapter can remain the implementation, but V2 should stabilize the interface.

Suggested gateway methods:
- `provisionMailboxAccount`
- `disableMailboxAccount`
- `deleteMailboxAccount`
- `resetMailboxPassword`
- `getMailboxAccount`
- `sendMailboxMessage`

The control plane should depend only on this gateway contract, not on Mailu-specific request details.

## 16. Observability

V2 must add structured observability rather than relying only on ad hoc logs and dashboard inspection.

Every workflow should carry:
- `request_id`
- `job_id`
- `tenant_id`
- `mailbox_account_id`
- `mailbox_lease_id`
- `message_id`
- `send_attempt_id`
- `webhook_delivery_id`

Recommended metrics:
- API latency by route
- queue depth by job type
- mailbox provision failure rate
- parse failure rate
- webhook retry rate
- send failure rate
- reconciliation findings

## 17. Testing Strategy

Keep the existing V1 route tests as compatibility coverage, but add deeper tests for the new model.

Recommended new test files:
- `test/services/mailbox-service.test.js`
- `test/services/message-service.test.js`
- `test/services/send-service.test.js`
- `test/jobs/mailbox-provision-job.test.js`
- `test/jobs/message-parse-job.test.js`
- `test/jobs/send-submit-job.test.js`
- `test/http/v2-mailboxes.test.js`
- `test/http/v2-messages.test.js`

Test focus:
- state transitions
- dedupe behavior
- async job retries
- read model correctness

## 18. Implementation Phases

### Phase 1

Deliver:
- new V2 tables
- Redis queue abstraction
- mailbox and send services
- mailbox provision and send jobs
- `docs/openapi-v2.yaml`

### Phase 2

Deliver:
- raw message and parse result pipeline
- parser worker
- webhook delivery jobs
- V1 compatibility paths backed by V2 internals

### Phase 3

Deliver:
- `/v2/*` public API
- read-model-backed admin and user APIs
- UI updates for new mailbox and send lifecycle

## 19. Execution Rules

To keep the migration controlled:
- do not big-bang rewrite V1
- do not add new business logic to `src/fetch-app.js`
- do not keep expanding monolithic storage classes
- add new functionality to services, repositories, and jobs first
- treat `/v1/*` as compatibility surface only
- put new contract work into `/v2/*`

## 20. Acceptance Criteria

The V2 design is successful only if:
- mailbox accounts can exist without active leases
- lease changes do not depend on synchronous Mailu request lifetime
- inbound messages are deduped and reparsable
- outbound messages are auditable as first-class records
- webhook delivery state is queryable independently
- a new engineer can understand boundaries from code layout

## 21. Recommended First Sprint

The first sprint should include only these items:
1. Add V2 schema tables.
2. Add Redis queue abstraction.
3. Implement `mailbox-service`.
4. Implement `send-service`.
5. Route V1 mailbox allocate and V1 send through the new services and jobs.
6. Add `docs/openapi-v2.yaml`.

This is the smallest set of work that moves the project from V1 extension mode into V2 migration mode.
