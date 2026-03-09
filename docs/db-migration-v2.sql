-- Mailagents V2 additive schema migration
-- This migration is designed to be additive against the current V1 schema.
-- It introduces the first V2 tables without dropping or rewriting V1 tables.

create extension if not exists pgcrypto;

create table if not exists mailbox_accounts (
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

create table if not exists mailbox_leases_v2 (
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

create unique index if not exists idx_mailbox_leases_v2_one_active
on mailbox_leases_v2(mailbox_account_id)
where lease_status in ('pending', 'active', 'releasing');

create index if not exists idx_mailbox_leases_v2_tenant
on mailbox_leases_v2(tenant_id, created_at desc);

create index if not exists idx_mailbox_leases_v2_agent
on mailbox_leases_v2(agent_id, created_at desc);

create table if not exists raw_messages (
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

create unique index if not exists idx_raw_messages_backend_unique
on raw_messages(mailbox_account_id, backend_message_id)
where backend_message_id is not null;

create index if not exists idx_raw_messages_account_received
on raw_messages(mailbox_account_id, received_at desc);

create table if not exists messages_v2 (
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

create index if not exists idx_messages_v2_tenant_received
on messages_v2(tenant_id, received_at desc);

create index if not exists idx_messages_v2_account_received
on messages_v2(mailbox_account_id, received_at desc);

create table if not exists message_parse_results (
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

create index if not exists idx_message_parse_results_message
on message_parse_results(message_id, created_at desc);

create table if not exists send_attempts (
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

create index if not exists idx_send_attempts_tenant_created
on send_attempts(tenant_id, created_at desc);

create index if not exists idx_send_attempts_account_created
on send_attempts(mailbox_account_id, created_at desc);

create index if not exists idx_send_attempts_status_created
on send_attempts(submission_status, created_at desc);

create table if not exists send_attempt_events (
  id uuid primary key default gen_random_uuid(),
  send_attempt_id uuid not null references send_attempts(id),
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_send_attempt_events_attempt
on send_attempt_events(send_attempt_id, created_at desc);

create table if not exists webhook_deliveries (
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

create index if not exists idx_webhook_deliveries_webhook
on webhook_deliveries(webhook_id, created_at desc);

create index if not exists idx_webhook_deliveries_resource
on webhook_deliveries(resource_id, created_at desc);

-- Backfill mailbox accounts from V1 mailboxes.
insert into mailbox_accounts (address, domain, backend_ref, backend_status, mailbox_type, created_at, updated_at)
select
  m.address,
  split_part(m.address, '@', 2) as domain,
  m.provider_ref,
  case
    when m.status = 'leased' then 'active'
    when m.status = 'available' then 'disabled'
    when m.status = 'frozen' then 'error'
    else 'disabled'
  end as backend_status,
  case
    when m.type is null or m.type = '' then 'pooled'
    else 'pooled'
  end as mailbox_type,
  m.created_at,
  now() as updated_at
from mailboxes m
on conflict (address) do nothing;

-- Backfill V2 leases from V1 leases.
insert into mailbox_leases_v2 (
  mailbox_account_id,
  tenant_id,
  agent_id,
  lease_status,
  purpose,
  started_at,
  ends_at,
  released_at,
  created_at,
  updated_at
)
select
  ma.id as mailbox_account_id,
  l.tenant_id,
  l.agent_id,
  case
    when l.status = 'active' then 'active'
    when l.status = 'released' then 'released'
    when l.status = 'expired' then 'expired'
    else 'released'
  end as lease_status,
  l.purpose,
  l.started_at,
  l.expires_at as ends_at,
  l.released_at,
  coalesce(l.started_at, now()) as created_at,
  now() as updated_at
from mailbox_leases l
join mailboxes m on m.id = l.mailbox_id
join mailbox_accounts ma on ma.address = m.address
where not exists (
  select 1
  from mailbox_leases_v2 l2
  where l2.mailbox_account_id = ma.id
    and l2.tenant_id = l.tenant_id
    and l2.agent_id = l.agent_id
    and l2.purpose = l.purpose
    and l2.ends_at = l.expires_at
);
