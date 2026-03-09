# Mailagents V2 Sprint 1 Implementation Plan

## Goal

Sprint 1 moves the project from V1 extension mode into V2 migration mode.

The sprint does not try to complete V2. It establishes the minimum technical foundation:
- V2 schema tables
- queue abstraction
- mailbox service
- send service
- first async job flow
- initial V2 contract documents

## Scope

In scope:
- add V2 database tables
- add Redis-backed queue abstraction
- introduce mailbox and send services
- route V1 mailbox allocation through the new service layer
- route V1 send through the new service layer
- add worker entrypoint
- add tests for service and job flows

Out of scope:
- full UI rewrite
- full admin API rewrite
- parser pipeline rewrite
- message list migration
- full V2 endpoint implementation

## Deliverables

1. `docs/db-migration-v2.sql`
2. `docs/openapi-v2.yaml`
3. `src/services/mailbox-service.js`
4. `src/services/send-service.js`
5. `src/jobs/queue.js`
6. `src/jobs/mailbox-provision-job.js`
7. `src/jobs/send-submit-job.js`
8. `src/workers/job-worker.js`
9. V1 route integration in the existing request path
10. New tests for services and jobs

## Proposed File Changes

### New files

```text
src/services/mailbox-service.js
src/services/send-service.js
src/jobs/queue.js
src/jobs/mailbox-provision-job.js
src/jobs/send-submit-job.js
src/workers/job-worker.js
src/repositories/postgres/mailbox-account-repo.js
src/repositories/postgres/mailbox-lease-repo.js
src/repositories/postgres/send-attempt-repo.js
test/services/mailbox-service.test.js
test/services/send-service.test.js
test/jobs/mailbox-provision-job.test.js
test/jobs/send-submit-job.test.js
```

### Existing files to modify

```text
src/fetch-app.js
src/store.js
src/storage/postgres-store.js
src/storage/memory-store.js
package.json
docker-compose.yml
docker-compose.prod.yml
```

## Work Breakdown

### Task 1: Add schema migration

Files:
- `docs/db-migration-v2.sql`
- optionally `scripts/db-migrate-v2.js`

Work:
- create `mailbox_accounts`
- create `mailbox_leases_v2`
- create `send_attempts`
- create `send_attempt_events`
- add indexes for lease and send lookups

Acceptance:
- migration runs cleanly on an existing V1 database
- migration is additive only

### Task 2: Add queue abstraction

Files:
- `src/jobs/queue.js`
- `package.json`

Work:
- define queue client interface
- support enqueueing mailbox provision and send submit jobs
- keep implementation isolated from business code

Acceptance:
- services depend on queue abstraction, not Redis details
- queue payloads include correlation identifiers

### Task 3: Add mailbox service

Files:
- `src/services/mailbox-service.js`
- repository files for account and lease access

Work:
- validate tenant and agent ownership
- create V2 lease row in `pending`
- allocate or choose mailbox account
- enqueue `mailbox.provision`
- expose V1 compatibility adapter if needed

Acceptance:
- service returns lease data with `pending` or `active` state
- no direct Mailu provisioning call in request path

### Task 4: Add send service

Files:
- `src/services/send-service.js`
- repository files for send attempts

Work:
- validate mailbox account or lease ownership
- create `send_attempts` row with `queued`
- enqueue `send.submit`
- provide lookup helpers for send status

Acceptance:
- request path no longer submits SMTP synchronously
- send attempt is auditable even if worker fails later

### Task 5: Add worker entrypoint

Files:
- `src/workers/job-worker.js`
- `src/jobs/mailbox-provision-job.js`
- `src/jobs/send-submit-job.js`

Work:
- start worker process
- process mailbox provision jobs
- process send submit jobs
- write state transitions and events

Acceptance:
- worker can be started independently
- failed jobs update entity state consistently

### Task 6: Integrate V1 routes with V2 internals

Files:
- `src/fetch-app.js`

Routes:
- `POST /v1/mailboxes/allocate`
- `POST /v1/messages/send`

Work:
- call new services from these routes
- preserve current auth and response compatibility where possible
- keep V1 path names but change internals

Acceptance:
- external clients can keep using V1
- backend behavior now depends on services and jobs

### Task 7: Add tests

Files:
- `test/services/mailbox-service.test.js`
- `test/services/send-service.test.js`
- `test/jobs/mailbox-provision-job.test.js`
- `test/jobs/send-submit-job.test.js`

Work:
- test state transitions
- test queue enqueue behavior
- test retry-safe writes
- test error paths

Acceptance:
- core async workflows are covered independently of route tests

## Suggested Sequence

1. Add schema and migration script.
2. Add queue abstraction.
3. Add repositories for mailbox and send.
4. Add mailbox service.
5. Add send service.
6. Add worker jobs.
7. Integrate V1 routes.
8. Add tests.
9. Update deployment config for Redis and worker process.

## Dependencies

Required:
- PostgreSQL
- Redis
- current Mailu adapter

Likely package additions:
- `ioredis` or equivalent
- `bullmq` if chosen for queue implementation

## Risks

### Risk 1: V1 compatibility drift

Mitigation:
- keep route-level compatibility tests
- keep V1 response fields during Sprint 1

### Risk 2: dual-write inconsistency

Mitigation:
- prefer V2 writes first, with V1 compatibility reads where possible
- add audit logging for transition points

### Risk 3: request path still depends on old store methods

Mitigation:
- put new logic behind services
- avoid adding new methods to monolithic store classes

## Definition of Done

Sprint 1 is done when:
- V2 tables exist
- Redis-backed queue exists
- mailbox allocation is job-driven
- outbound send is job-driven
- worker process runs these jobs
- V1 compatibility still works
- tests cover service and job flows

## Suggested PR Breakdown

1. `v2-schema-and-queue-foundation`
2. `v2-mailbox-service-and-provision-job`
3. `v2-send-service-and-send-job`
4. `wire-v1-routes-to-v2-services`
5. `add-sprint-1-tests`
