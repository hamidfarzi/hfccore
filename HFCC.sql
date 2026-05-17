-- HFCC (Hamid Farzi Central Core) for Supabase PostgreSQL.
-- This migration intentionally avoids PostgreSQL ENUMs. Runtime codes,
-- statuses, categories, and channels are stored as text and constrained
-- through hfcc.types with scoped foreign keys and CHECK constraints.

create schema if not exists extensions;
create schema if not exists hfcc;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Central type registry
-- ---------------------------------------------------------------------------

create table if not exists hfcc.types (
  code text primary key,
  schema text not null default 'hfcc',
  entity text not null,
  field text not null,
  label text,
  description text,
  invoke_functions jsonb not null default '[]'::jsonb,
  log_audit boolean not null default false,
  log_activity boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint types_schema_name_check
    check (schema ~ '^[a-z][a-z0-9_]*$'),
  constraint types_entity_name_check
    check (entity ~ '^[a-z][a-z0-9_]*$'),
  constraint types_field_name_check
    check (field ~ '^[a-z][a-z0-9_]*$'),
  constraint types_code_namespaced_check
    check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){3,}$'),
  constraint types_code_scoped_name_check
    check (left(code, length(schema || '.' || entity || '.' || field || '.')) = schema || '.' || entity || '.' || field || '.'),
  constraint types_invoke_functions_array_check
    check (jsonb_typeof(invoke_functions) = 'array'),
  constraint types_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists types_entity_field_code_idx
  on hfcc.types (schema, entity, field, code);

create index if not exists types_entity_field_active_idx
  on hfcc.types (schema, entity, field, is_active, sort_order, code);

comment on table hfcc.types is
  'Central registry for all reusable HFCC codes. No PostgreSQL ENUMs are used.';
comment on column hfcc.types.code is
  'Scoped namespaced code that must follow schema.entity.field.*, such as hfcc.subscriptions.status_code.active.';

create or replace function hfcc.is_valid_type(
  p_code text,
  p_schema text,
  p_entity text,
  p_field text
)
returns boolean
language sql
stable
set search_path = hfcc
as $$
  select exists (
    select 1
    from hfcc.types t
    where t.code = p_code
      and t.schema = p_schema
      and t.entity = p_entity
      and t.field = p_field
      and t.is_active
  );
$$;

create or replace function hfcc.is_valid_type(
  p_code text,
  p_entity text,
  p_field text
)
returns boolean
language sql
stable
set search_path = hfcc
as $$
  select hfcc.is_valid_type(p_code, 'hfcc', p_entity, p_field);
$$;

-- ---------------------------------------------------------------------------
-- Base type seeds
-- ---------------------------------------------------------------------------

insert into hfcc.types (code, schema, entity, field, label, description, sort_order)
values
  -- Users
  ('hfcc.users.role_code.user', 'hfcc', 'users', 'role_code', 'User', 'Default normal application user.', 10),
  ('hfcc.users.role_code.admin', 'hfcc', 'users', 'role_code', 'Admin', 'Application administrator user.', 20),
  ('hfcc.users.role_code.system', 'hfcc', 'users', 'role_code', 'System', 'Internal system actor user.', 30),
  ('hfcc.users.role_code.support', 'hfcc', 'users', 'role_code', 'Support', 'Support or operator user.', 40),

  -- Settings
  ('hfcc.settings.scope_type.global', 'hfcc', 'settings', 'scope_type', 'Global', 'Global setting shared across the app.', 10),
  ('hfcc.settings.scope_type.user', 'hfcc', 'settings', 'scope_type', 'User', 'Setting owned by a HFCC user.', 20),
  ('hfcc.settings.scope_type.org', 'hfcc', 'settings', 'scope_type', 'Organization', 'Setting owned by an organization.', 30),
  ('hfcc.settings.scope_type.app', 'hfcc', 'settings', 'scope_type', 'App', 'Setting owned by an app namespace.', 40),
  ('hfcc.settings.scope_type.system', 'hfcc', 'settings', 'scope_type', 'System', 'Internal system setting.', 50),

  -- Outbox
  ('hfcc.events_outbox.event_code.message.send_requested', 'hfcc', 'events_outbox', 'event_code', 'Send message requested', 'Dispatch an outgoing message through its provider.', 10),
  ('hfcc.events_outbox.event_code.message.escalation_due', 'hfcc', 'events_outbox', 'event_code', 'Message escalation due', 'Evaluate an unread message and enqueue the next configured delivery channel.', 12),
  ('hfcc.events_outbox.event_code.webhook.dispatch_requested', 'hfcc', 'events_outbox', 'event_code', 'Dispatch webhook requested', 'Dispatch an external webhook.', 20),
  ('hfcc.events_outbox.event_code.integration.publish_requested', 'hfcc', 'events_outbox', 'event_code', 'Publish integration event requested', 'Publish an integration event to an external bus.', 30),
  ('hfcc.events_outbox.event_code.subscription.renewed', 'hfcc', 'events_outbox', 'event_code', 'Subscription renewed', 'Notify integrations about subscription renewal.', 40),
  ('hfcc.events_outbox.event_code.subscription.renewal_notice_requested', 'hfcc', 'events_outbox', 'event_code', 'Subscription renewal notice requested', 'Request app-specific renewal notice delivery.', 45),
  ('hfcc.events_outbox.source_type.subscription', 'hfcc', 'events_outbox', 'source_type', 'Subscription', 'Outbox request caused by a subscription.', 10),
  ('hfcc.events_outbox.source_type.outgoing_message', 'hfcc', 'events_outbox', 'source_type', 'Outgoing message', 'Outbox request caused by an outgoing message row.', 20),
  ('hfcc.events_outbox.source_type.job', 'hfcc', 'events_outbox', 'source_type', 'Job', 'Outbox request caused by a scheduled job.', 30),
  ('hfcc.events_outbox.source_type.manual', 'hfcc', 'events_outbox', 'source_type', 'Manual', 'Outbox request created manually by service logic.', 40),
  ('hfcc.events_outbox.source_type.commerce_order', 'hfcc', 'events_outbox', 'source_type', 'Commerce order', 'Outbox request caused by a commerce order.', 50),
  ('hfcc.events_outbox.source_type.commerce_order_item', 'hfcc', 'events_outbox', 'source_type', 'Commerce order item', 'Outbox request caused by a commerce order item.', 60),
  ('hfcc.events_outbox.status_code.pending', 'hfcc', 'events_outbox', 'status_code', 'Pending', 'Waiting to be claimed.', 10),
  ('hfcc.events_outbox.status_code.processing', 'hfcc', 'events_outbox', 'status_code', 'Processing', 'Claimed by a worker.', 20),
  ('hfcc.events_outbox.status_code.done', 'hfcc', 'events_outbox', 'status_code', 'Done', 'Processed successfully.', 30),
  ('hfcc.events_outbox.status_code.sent', 'hfcc', 'events_outbox', 'status_code', 'Sent', 'Delivered to the external transport.', 35),
  ('hfcc.events_outbox.status_code.failed', 'hfcc', 'events_outbox', 'status_code', 'Failed', 'Processing failed.', 40),
  ('hfcc.events_outbox.status_code.cancelled', 'hfcc', 'events_outbox', 'status_code', 'Cancelled', 'Processing was cancelled.', 50),

  -- Inbox
  ('hfcc.events_inbox.source_code.openai', 'hfcc', 'events_inbox', 'source_code', 'OpenAI', 'Events received from OpenAI.', 10),
  ('hfcc.events_inbox.source_code.stripe', 'hfcc', 'events_inbox', 'source_code', 'Stripe', 'Events received from Stripe.', 20),
  ('hfcc.events_inbox.source_code.sendgrid', 'hfcc', 'events_inbox', 'source_code', 'SendGrid', 'Events received from SendGrid.', 30),
  ('hfcc.events_inbox.source_code.twilio', 'hfcc', 'events_inbox', 'source_code', 'Twilio', 'Events received from Twilio.', 40),
  ('hfcc.events_inbox.source_code.webhook', 'hfcc', 'events_inbox', 'source_code', 'Webhook', 'Generic webhook source.', 50),
  ('hfcc.events_inbox.event_code.openai.response.completed', 'hfcc', 'events_inbox', 'event_code', 'OpenAI response completed', 'An OpenAI response completed.', 10),
  ('hfcc.events_inbox.event_code.stripe.payment.succeeded', 'hfcc', 'events_inbox', 'event_code', 'Stripe payment succeeded', 'Stripe reported a successful payment.', 20),
  ('hfcc.events_inbox.event_code.stripe.payment.failed', 'hfcc', 'events_inbox', 'event_code', 'Stripe payment failed', 'Stripe reported a failed payment.', 30),
  ('hfcc.events_inbox.event_code.stripe.subscription.updated', 'hfcc', 'events_inbox', 'event_code', 'Stripe subscription updated', 'Stripe reported a subscription update.', 40),
  ('hfcc.events_inbox.event_code.webhook.received', 'hfcc', 'events_inbox', 'event_code', 'Webhook received', 'A generic webhook was received.', 50),
  ('hfcc.events_inbox.event_code.payment.completed', 'hfcc', 'events_inbox', 'event_code', 'Payment completed', 'A payment provider reported completion.', 60),
  ('hfcc.events_inbox.status_code.pending', 'hfcc', 'events_inbox', 'status_code', 'Pending', 'Waiting to be processed.', 10),
  ('hfcc.events_inbox.status_code.received', 'hfcc', 'events_inbox', 'status_code', 'Received', 'Received and waiting to be processed.', 15),
  ('hfcc.events_inbox.status_code.processing', 'hfcc', 'events_inbox', 'status_code', 'Processing', 'Claimed by a worker.', 20),
  ('hfcc.events_inbox.status_code.done', 'hfcc', 'events_inbox', 'status_code', 'Done', 'Processed successfully.', 30),
  ('hfcc.events_inbox.status_code.failed', 'hfcc', 'events_inbox', 'status_code', 'Failed', 'Processing failed.', 40),

  -- Jobs
  ('hfcc.jobs.job_code.subscription.expire', 'hfcc', 'jobs', 'job_code', 'Expire subscription', 'Expire subscriptions whose period ended.', 10),
  ('hfcc.jobs.job_code.subscription.renew', 'hfcc', 'jobs', 'job_code', 'Renew subscription', 'Renew eligible subscriptions.', 20),
  ('hfcc.jobs.job_code.message.retry', 'hfcc', 'jobs', 'job_code', 'Retry message', 'Retry failed outgoing messages.', 30),
  ('hfcc.jobs.job_code.outbox.retry', 'hfcc', 'jobs', 'job_code', 'Retry outbox', 'Retry stuck outbox events.', 40),
  ('hfcc.jobs.job_code.promotion.expire', 'hfcc', 'jobs', 'job_code', 'Expire promotion', 'Deactivate expired promotions.', 50),
  ('hfcc.jobs.job_code.audit.prune', 'hfcc', 'jobs', 'job_code', 'Prune audit logs', 'Prune audit logs according to retention settings.', 60),
  ('hfcc.jobs.job_code.subscription.maintenance_daily', 'hfcc', 'jobs', 'job_code', 'Daily subscription maintenance', 'Daily subscription maintenance and entitlement reconciliation.', 70),
  ('hfcc.jobs.job_code.subscription.activate', 'hfcc', 'jobs', 'job_code', 'Start subscription renewal payment', 'Create or reuse the renewal order payment intent at the next subscription period boundary.', 80),
  ('hfcc.jobs.job_code.subscription.renewal_notice', 'hfcc', 'jobs', 'job_code', 'Subscription renewal notice', 'Notify a user before a renewal order is due.', 90),
  ('hfcc.jobs.source_type.subscription', 'hfcc', 'jobs', 'source_type', 'Subscription', 'Job created for a subscription.', 10),
  ('hfcc.jobs.source_type.manual', 'hfcc', 'jobs', 'source_type', 'Manual', 'Job created manually by service logic.', 20),
  ('hfcc.jobs.source_type.commerce_order', 'hfcc', 'jobs', 'source_type', 'Commerce order', 'Job created for a commerce order.', 30),
  ('hfcc.jobs.status_code.pending', 'hfcc', 'jobs', 'status_code', 'Pending', 'Waiting to be claimed.', 10),
  ('hfcc.jobs.status_code.processing', 'hfcc', 'jobs', 'status_code', 'Processing', 'Claimed by a worker.', 20),
  ('hfcc.jobs.status_code.done', 'hfcc', 'jobs', 'status_code', 'Done', 'Processed successfully.', 30),
  ('hfcc.jobs.status_code.failed', 'hfcc', 'jobs', 'status_code', 'Failed', 'Processing failed.', 40),
  ('hfcc.jobs.status_code.cancelled', 'hfcc', 'jobs', 'status_code', 'Cancelled', 'Job was cancelled.', 50),

  -- Messages
  ('hfcc.outgoing_messages.status_code.pending', 'hfcc', 'outgoing_messages', 'status_code', 'Pending', 'Waiting to be sent.', 10),
  ('hfcc.outgoing_messages.status_code.sending', 'hfcc', 'outgoing_messages', 'status_code', 'Sending', 'Provider request is in progress.', 20),
  ('hfcc.outgoing_messages.status_code.sent', 'hfcc', 'outgoing_messages', 'status_code', 'Sent', 'Message was sent.', 30),
  ('hfcc.outgoing_messages.status_code.failed', 'hfcc', 'outgoing_messages', 'status_code', 'Failed', 'Message failed.', 40),
  ('hfcc.outgoing_messages.channel_code.inapp', 'hfcc', 'outgoing_messages', 'channel_code', 'In-app', 'In-application notification channel.', 5),
  ('hfcc.outgoing_messages.channel_code.email', 'hfcc', 'outgoing_messages', 'channel_code', 'Email', 'Email delivery channel.', 10),
  ('hfcc.outgoing_messages.channel_code.sms', 'hfcc', 'outgoing_messages', 'channel_code', 'SMS', 'SMS delivery channel.', 20),
  ('hfcc.outgoing_messages.channel_code.push', 'hfcc', 'outgoing_messages', 'channel_code', 'Push', 'Push notification delivery channel.', 30),
  ('hfcc.outgoing_messages.channel_code.webhook', 'hfcc', 'outgoing_messages', 'channel_code', 'Webhook', 'Webhook delivery channel.', 40),
  ('hfcc.outgoing_messages.template_code.subscription_renewal_notice', 'hfcc', 'outgoing_messages', 'template_code', 'Subscription renewal notice', 'Template for subscription renewal reminders.', 10),
  ('hfcc.outgoing_messages.provider_code.inapp', 'hfcc', 'outgoing_messages', 'provider_code', 'In-app', 'Internal in-app notification provider.', 5),
  ('hfcc.outgoing_messages.provider_code.smtp', 'hfcc', 'outgoing_messages', 'provider_code', 'SMTP', 'SMTP email provider.', 10),
  ('hfcc.outgoing_messages.provider_code.sendgrid', 'hfcc', 'outgoing_messages', 'provider_code', 'SendGrid', 'SendGrid provider.', 20),
  ('hfcc.outgoing_messages.provider_code.twilio', 'hfcc', 'outgoing_messages', 'provider_code', 'Twilio', 'Twilio provider.', 30),
  ('hfcc.outgoing_messages.provider_code.fcm', 'hfcc', 'outgoing_messages', 'provider_code', 'FCM', 'Firebase Cloud Messaging provider.', 40),
  ('hfcc.outgoing_messages.provider_code.apns', 'hfcc', 'outgoing_messages', 'provider_code', 'APNS', 'Apple Push Notification service provider.', 50),
  ('hfcc.outgoing_messages.provider_code.postmark', 'hfcc', 'outgoing_messages', 'provider_code', 'Postmark', 'Postmark email provider.', 60),
  ('hfcc.outgoing_messages.provider_code.webhook', 'hfcc', 'outgoing_messages', 'provider_code', 'Webhook', 'Generic webhook provider.', 70),
  ('hfcc.outgoing_messages.provider_code.custom', 'hfcc', 'outgoing_messages', 'provider_code', 'Custom', 'Custom message provider.', 80),
  ('hfcc.outgoing_messages.source_type.subscription', 'hfcc', 'outgoing_messages', 'source_type', 'Subscription', 'Message requested by subscription service logic.', 10),
  ('hfcc.outgoing_messages.source_type.job', 'hfcc', 'outgoing_messages', 'source_type', 'Job', 'Message requested by scheduled job processing.', 20),
  ('hfcc.outgoing_messages.source_type.manual', 'hfcc', 'outgoing_messages', 'source_type', 'Manual', 'Message requested manually by service logic.', 30),
  ('hfcc.outgoing_messages.source_type.commerce_order', 'hfcc', 'outgoing_messages', 'source_type', 'Commerce order', 'Message requested by commerce order service logic.', 40),

  -- Devices
  ('hfcc.devices.platform_code.ios', 'hfcc', 'devices', 'platform_code', 'iOS', 'Apple iOS device.', 10),
  ('hfcc.devices.platform_code.android', 'hfcc', 'devices', 'platform_code', 'Android', 'Android device.', 20),
  ('hfcc.devices.platform_code.web', 'hfcc', 'devices', 'platform_code', 'Web', 'Web browser device.', 30),
  ('hfcc.devices.platform_code.desktop', 'hfcc', 'devices', 'platform_code', 'Desktop', 'Desktop app device.', 40),
  ('hfcc.devices.platform_code.server', 'hfcc', 'devices', 'platform_code', 'Server', 'Server-side device or integration endpoint.', 50),
  ('hfcc.devices.push_provider_code.apns', 'hfcc', 'devices', 'push_provider_code', 'APNS', 'Apple Push Notification service.', 10),
  ('hfcc.devices.push_provider_code.fcm', 'hfcc', 'devices', 'push_provider_code', 'FCM', 'Firebase Cloud Messaging.', 20),
  ('hfcc.devices.push_provider_code.web', 'hfcc', 'devices', 'push_provider_code', 'Web push', 'Browser web push.', 30),
  ('hfcc.devices.push_provider_code.expo', 'hfcc', 'devices', 'push_provider_code', 'Expo', 'Expo push notification service.', 40),

  -- Ledger
  ('hfcc.ledger_currencies.type_code.fiat', 'hfcc', 'ledger_currencies', 'type_code', 'Fiat', 'Money-like fiat currency.', 10),
  ('hfcc.ledger_currencies.type_code.points', 'hfcc', 'ledger_currencies', 'type_code', 'Points', 'Loyalty points currency.', 20),
  ('hfcc.ledger_currencies.type_code.credit', 'hfcc', 'ledger_currencies', 'type_code', 'Credit', 'Credit balance currency.', 30),
  ('hfcc.ledger_currencies.type_code.token', 'hfcc', 'ledger_currencies', 'type_code', 'Token', 'Tokenized or app-specific transferable unit.', 40),
  ('hfcc.ledger_currencies.type_code.entitlement', 'hfcc', 'ledger_currencies', 'type_code', 'Entitlement', 'Non-fiat entitlement value managed through ledger grants.', 50),
  ('hfcc.ledger_accounts.owner_type.user', 'hfcc', 'ledger_accounts', 'owner_type', 'User', 'Account owned by a HFCC user.', 5),
  ('hfcc.ledger_accounts.owner_type.system', 'hfcc', 'ledger_accounts', 'owner_type', 'System', 'Account owned by a system user or system actor.', 6),
  ('hfcc.ledger_accounts.owner_type.shop', 'hfcc', 'ledger_accounts', 'owner_type', 'Shop', 'Account owned by a shop.', 7),
  ('hfcc.ledger_accounts.owner_type.org', 'hfcc', 'ledger_accounts', 'owner_type', 'Organization', 'Account owned by an organization.', 8),
  ('hfcc.ledger_accounts.account_type_code.user_wallet', 'hfcc', 'ledger_accounts', 'account_type_code', 'User wallet', 'User-owned wallet account.', 10),
  ('hfcc.ledger_accounts.account_type_code.system', 'hfcc', 'ledger_accounts', 'account_type_code', 'System', 'System account.', 20),
  ('hfcc.ledger_accounts.account_type_code.liability', 'hfcc', 'ledger_accounts', 'account_type_code', 'Liability', 'Liability account.', 30),
  ('hfcc.ledger_accounts.account_type_code.revenue', 'hfcc', 'ledger_accounts', 'account_type_code', 'Revenue', 'Revenue account.', 40),
  ('hfcc.ledger_accounts.account_type_code.promotion_pool', 'hfcc', 'ledger_accounts', 'account_type_code', 'Promotion pool', 'Pool account used for promotions.', 50),
  ('hfcc.ledger_accounts.account_type_code.escrow', 'hfcc', 'ledger_accounts', 'account_type_code', 'Escrow', 'Escrow or holding account.', 60),
  ('hfcc.ledger_transactions.transaction_code.reward', 'hfcc', 'ledger_transactions', 'transaction_code', 'Reward', 'Credit a loyalty reward.', 10),
  ('hfcc.ledger_transactions.transaction_code.adjustment', 'hfcc', 'ledger_transactions', 'transaction_code', 'Adjustment', 'Manual or system adjustment.', 20),
  ('hfcc.ledger_transactions.transaction_code.purchase', 'hfcc', 'ledger_transactions', 'transaction_code', 'Purchase', 'Purchase transaction.', 30),
  ('hfcc.ledger_transactions.transaction_code.payment', 'hfcc', 'ledger_transactions', 'transaction_code', 'Payment', 'Payment transaction.', 35),
  ('hfcc.ledger_transactions.transaction_code.refund', 'hfcc', 'ledger_transactions', 'transaction_code', 'Refund', 'Refund transaction.', 40),
  ('hfcc.ledger_transactions.transaction_code.promotion_grant', 'hfcc', 'ledger_transactions', 'transaction_code', 'Promotion grant', 'Grant value from a promotion.', 50),
  ('hfcc.ledger_transactions.transaction_code.wallet_grant', 'hfcc', 'ledger_transactions', 'transaction_code', 'Wallet grant', 'Grant wallet value from a wallet grant.', 60),
  ('hfcc.ledger_transactions.transaction_code.wallet_grant_expiry', 'hfcc', 'ledger_transactions', 'transaction_code', 'Wallet grant expiry', 'Expire unused value from a previous wallet grant.', 70),
  ('hfcc.ledger_transactions.source_type.ledger', 'hfcc', 'ledger_transactions', 'source_type', 'Ledger', 'Ledger transaction created by ledger service logic.', 10),
  ('hfcc.ledger_transactions.source_type.subscription', 'hfcc', 'ledger_transactions', 'source_type', 'Subscription', 'Ledger transaction caused by a subscription wallet grant.', 20),
  ('hfcc.ledger_transactions.source_type.promotion_usage', 'hfcc', 'ledger_transactions', 'source_type', 'Promotion usage', 'Ledger transaction caused by promotion usage.', 30),
  ('hfcc.ledger_transactions.source_type.manual', 'hfcc', 'ledger_transactions', 'source_type', 'Manual', 'Ledger transaction created manually by service logic.', 40),
  ('hfcc.ledger_transactions.source_type.commerce_order', 'hfcc', 'ledger_transactions', 'source_type', 'Commerce order', 'Ledger transaction caused by a commerce order.', 50),
  ('hfcc.ledger_transactions.source_type.commerce_order_item', 'hfcc', 'ledger_transactions', 'source_type', 'Commerce order item', 'Ledger transaction caused by a commerce order item.', 60),

  -- Subscription and payment
  ('hfcc.commerce_orders.billing_interval_code.week', 'hfcc', 'commerce_orders', 'billing_interval_code', 'Weekly', 'Billed weekly.', 10),
  ('hfcc.commerce_orders.billing_interval_code.month', 'hfcc', 'commerce_orders', 'billing_interval_code', 'Monthly', 'Billed monthly.', 20),
  ('hfcc.commerce_orders.billing_interval_code.year', 'hfcc', 'commerce_orders', 'billing_interval_code', 'Yearly', 'Billed yearly.', 30),
  ('hfcc.commerce_orders.billing_interval_code.once', 'hfcc', 'commerce_orders', 'billing_interval_code', 'One time', 'Charged once.', 40),
  ('hfcc.commerce_orders.billing_interval_code.day', 'hfcc', 'commerce_orders', 'billing_interval_code', 'Daily', 'Billed daily.', 50),
  ('hfcc.ledger_wallet_grants.recharge_interval_code.once', 'hfcc', 'ledger_wallet_grants', 'recharge_interval_code', 'Once', 'Granted once on subscription activation.', 10),
  ('hfcc.ledger_wallet_grants.recharge_interval_code.day', 'hfcc', 'ledger_wallet_grants', 'recharge_interval_code', 'Daily', 'Recharged daily.', 20),
  ('hfcc.ledger_wallet_grants.recharge_interval_code.week', 'hfcc', 'ledger_wallet_grants', 'recharge_interval_code', 'Weekly', 'Recharged weekly.', 30),
  ('hfcc.ledger_wallet_grants.recharge_interval_code.month', 'hfcc', 'ledger_wallet_grants', 'recharge_interval_code', 'Monthly', 'Recharged monthly.', 40),
  ('hfcc.ledger_wallet_grants.recharge_interval_code.year', 'hfcc', 'ledger_wallet_grants', 'recharge_interval_code', 'Yearly', 'Recharged yearly.', 50),
  ('hfcc.ledger_wallet_grants.source_type.subscription', 'hfcc', 'ledger_wallet_grants', 'source_type', 'Subscription', 'Wallet grant originated from a subscription.', 10),
  ('hfcc.ledger_wallet_grants.source_type.commerce_order_item', 'hfcc', 'ledger_wallet_grants', 'source_type', 'Commerce order item', 'Wallet grant originated from a commerce order item.', 20),
  ('hfcc.ledger_wallet_grants.source_type.promotion_usage', 'hfcc', 'ledger_wallet_grants', 'source_type', 'Promotion usage', 'Wallet grant originated from promotion usage.', 30),
  ('hfcc.ledger_wallet_grants.source_type.manual', 'hfcc', 'ledger_wallet_grants', 'source_type', 'Manual', 'Wallet grant originated from manual service logic.', 40),
  ('hfcc.ledger_wallet_grants.status_code.active', 'hfcc', 'ledger_wallet_grants', 'status_code', 'Active', 'Wallet grant is active and can recharge.', 10),
  ('hfcc.ledger_wallet_grants.status_code.paused', 'hfcc', 'ledger_wallet_grants', 'status_code', 'Paused', 'Wallet grant is temporarily paused.', 20),
  ('hfcc.ledger_wallet_grants.status_code.expired', 'hfcc', 'ledger_wallet_grants', 'status_code', 'Expired', 'Wallet grant has expired.', 30),
  ('hfcc.ledger_wallet_grants.status_code.cancelled', 'hfcc', 'ledger_wallet_grants', 'status_code', 'Cancelled', 'Wallet grant was cancelled.', 40),
  ('hfcc.subscriptions.status_code.draft', 'hfcc', 'subscriptions', 'status_code', 'Draft', 'Draft subscription.', 10),
  ('hfcc.subscriptions.status_code.active', 'hfcc', 'subscriptions', 'status_code', 'Active', 'Currently active subscription.', 20),
  ('hfcc.subscriptions.status_code.paused', 'hfcc', 'subscriptions', 'status_code', 'Paused', 'Subscription is paused while renewal payment is pending.', 30),
  ('hfcc.subscriptions.status_code.expired', 'hfcc', 'subscriptions', 'status_code', 'Expired', 'Expired subscription.', 40),
  ('hfcc.subscriptions.status_code.cancelled', 'hfcc', 'subscriptions', 'status_code', 'Cancelled', 'Cancelled subscription.', 50),
  ('hfcc.subscriptions.payment_status_code.pending', 'hfcc', 'subscriptions', 'payment_status_code', 'Pending', 'Payment pending.', 10),
  ('hfcc.subscriptions.payment_status_code.paid', 'hfcc', 'subscriptions', 'payment_status_code', 'Paid', 'Payment completed.', 20),
  ('hfcc.subscriptions.payment_status_code.failed', 'hfcc', 'subscriptions', 'payment_status_code', 'Failed', 'Payment failed.', 30),
  ('hfcc.subscriptions.payment_status_code.refunded', 'hfcc', 'subscriptions', 'payment_status_code', 'Refunded', 'Payment refunded.', 40),

  -- Promotions
  ('hfcc.promotions.promotion_type_code.coupon', 'hfcc', 'promotions', 'promotion_type_code', 'Coupon', 'Coupon promotion.', 10),
  ('hfcc.promotions.promotion_type_code.referral', 'hfcc', 'promotions', 'promotion_type_code', 'Referral', 'Referral promotion.', 20),
  ('hfcc.promotions.promotion_type_code.promo', 'hfcc', 'promotions', 'promotion_type_code', 'Promo', 'General promotional campaign.', 30),
  ('hfcc.promotions.promotion_type_code.loyalty', 'hfcc', 'promotions', 'promotion_type_code', 'Loyalty', 'Loyalty program promotion.', 40),
  ('hfcc.promotions.promotion_type_code.reward', 'hfcc', 'promotions', 'promotion_type_code', 'Reward', 'Reward promotion that grants value after an eligible action.', 50),
  ('hfcc.promotion_usages.source_type.manual', 'hfcc', 'promotion_usages', 'source_type', 'Manual', 'Promotion usage created manually by service logic.', 10),
  ('hfcc.promotion_usages.source_type.commerce_order', 'hfcc', 'promotion_usages', 'source_type', 'Commerce order', 'Promotion usage created for a commerce order.', 20),
  ('hfcc.promotion_usages.source_type.referral', 'hfcc', 'promotion_usages', 'source_type', 'Referral', 'Promotion usage created from a referral flow.', 30),
  ('hfcc.promotion_usages.source_type.reward', 'hfcc', 'promotion_usages', 'source_type', 'Reward', 'Promotion usage created from a reward flow.', 40),

  -- Commerce
  ('hfcc.commerce_products.product_type_code.digital', 'hfcc', 'commerce_products', 'product_type_code', 'Digital', 'Generic digital product.', 10),
  ('hfcc.commerce_products.product_type_code.physical', 'hfcc', 'commerce_products', 'product_type_code', 'Physical', 'Generic physical product.', 20),
  ('hfcc.commerce_products.product_type_code.service', 'hfcc', 'commerce_products', 'product_type_code', 'Service', 'Service product.', 30),
  ('hfcc.commerce_products.product_type_code.ledger_wallet_grant', 'hfcc', 'commerce_products', 'product_type_code', 'Ledger wallet grant', 'Product that grants ledger wallet value.', 40),
  ('hfcc.commerce_products.product_type_code.bundle', 'hfcc', 'commerce_products', 'product_type_code', 'Bundle', 'Bundle of multiple product behaviors.', 50),
  ('hfcc.commerce_products.status_code.draft', 'hfcc', 'commerce_products', 'status_code', 'Draft', 'Product is not ready for sale.', 10),
  ('hfcc.commerce_products.status_code.active', 'hfcc', 'commerce_products', 'status_code', 'Active', 'Product is active.', 20),
  ('hfcc.commerce_products.status_code.archived', 'hfcc', 'commerce_products', 'status_code', 'Archived', 'Product is archived.', 30),
  ('hfcc.commerce_orders.status_code.draft', 'hfcc', 'commerce_orders', 'status_code', 'Draft', 'Order is being prepared.', 10),
  ('hfcc.commerce_orders.status_code.pending', 'hfcc', 'commerce_orders', 'status_code', 'Pending', 'Order is waiting for payment or confirmation.', 20),
  ('hfcc.commerce_orders.status_code.confirmed', 'hfcc', 'commerce_orders', 'status_code', 'Confirmed', 'Order has been confirmed.', 30),
  ('hfcc.commerce_orders.status_code.completed', 'hfcc', 'commerce_orders', 'status_code', 'Completed', 'Order has completed.', 40),
  ('hfcc.commerce_orders.status_code.cancelled', 'hfcc', 'commerce_orders', 'status_code', 'Cancelled', 'Order was cancelled.', 50),
  ('hfcc.commerce_orders.status_code.refunded', 'hfcc', 'commerce_orders', 'status_code', 'Refunded', 'Order was refunded.', 60),
  ('hfcc.commerce_orders.status_code.partially_refunded', 'hfcc', 'commerce_orders', 'status_code', 'Partially refunded', 'Some order items were refunded.', 65),
  ('hfcc.commerce_orders.status_code.failed', 'hfcc', 'commerce_orders', 'status_code', 'Failed', 'Order failed.', 70),
  ('hfcc.commerce_orders.order_type_code.one_time', 'hfcc', 'commerce_orders', 'order_type_code', 'One time', 'One-time commerce order.', 10),
  ('hfcc.commerce_orders.order_type_code.subscription_initial', 'hfcc', 'commerce_orders', 'order_type_code', 'Subscription initial', 'Initial order that creates a subscription.', 20),
  ('hfcc.commerce_orders.order_type_code.subscription_renewal', 'hfcc', 'commerce_orders', 'order_type_code', 'Subscription renewal', 'Renewal order for an existing subscription.', 30),
  ('hfcc.commerce_orders.order_type_code.adjustment', 'hfcc', 'commerce_orders', 'order_type_code', 'Adjustment', 'Commerce adjustment order.', 40),
  ('hfcc.commerce_orders.payment_status_code.unpaid', 'hfcc', 'commerce_orders', 'payment_status_code', 'Unpaid', 'No payment has been captured.', 10),
  ('hfcc.commerce_orders.payment_status_code.pending', 'hfcc', 'commerce_orders', 'payment_status_code', 'Pending', 'Payment is pending.', 20),
  ('hfcc.commerce_orders.payment_status_code.paid', 'hfcc', 'commerce_orders', 'payment_status_code', 'Paid', 'Payment is paid.', 30),
  ('hfcc.commerce_orders.payment_status_code.partially_refunded', 'hfcc', 'commerce_orders', 'payment_status_code', 'Partially refunded', 'Payment was partially refunded.', 40),
  ('hfcc.commerce_orders.payment_status_code.refunded', 'hfcc', 'commerce_orders', 'payment_status_code', 'Refunded', 'Payment was fully refunded.', 50),
  ('hfcc.commerce_orders.payment_status_code.failed', 'hfcc', 'commerce_orders', 'payment_status_code', 'Failed', 'Payment failed.', 60),
  ('hfcc.commerce_order_items.status_code.pending', 'hfcc', 'commerce_order_items', 'status_code', 'Pending', 'Order item is pending.', 10),
  ('hfcc.commerce_order_items.status_code.processing', 'hfcc', 'commerce_order_items', 'status_code', 'Processing', 'Order item is being processed.', 20),
  ('hfcc.commerce_order_items.status_code.completed', 'hfcc', 'commerce_order_items', 'status_code', 'Completed', 'Order item completed.', 30),
  ('hfcc.commerce_order_items.status_code.cancelled', 'hfcc', 'commerce_order_items', 'status_code', 'Cancelled', 'Order item was cancelled.', 40),
  ('hfcc.commerce_order_items.status_code.refunded', 'hfcc', 'commerce_order_items', 'status_code', 'Refunded', 'Order item was refunded.', 50),
  ('hfcc.commerce_order_items.status_code.failed', 'hfcc', 'commerce_order_items', 'status_code', 'Failed', 'Order item processing failed.', 60),
  ('hfcc.commerce_payment_methods.provider_code.stripe', 'hfcc', 'commerce_payment_methods', 'provider_code', 'Stripe', 'Stripe payment provider.', 10),
  ('hfcc.commerce_payment_methods.provider_code.paypal', 'hfcc', 'commerce_payment_methods', 'provider_code', 'PayPal', 'PayPal payment provider.', 20),
  ('hfcc.commerce_payment_methods.provider_code.manual', 'hfcc', 'commerce_payment_methods', 'provider_code', 'Manual', 'Manual payment provider.', 30),
  ('hfcc.commerce_payment_methods.provider_code.external', 'hfcc', 'commerce_payment_methods', 'provider_code', 'External', 'External payment provider.', 40),
  ('hfcc.commerce_payment_methods.provider_code.ledger', 'hfcc', 'commerce_payment_methods', 'provider_code', 'Ledger', 'Internal ledger balance payment provider.', 50),
  ('hfcc.commerce_payment_methods.payment_method_type_code.card', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'Card', 'Card payment method.', 10),
  ('hfcc.commerce_payment_methods.payment_method_type_code.bank_account', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'Bank account', 'Bank account payment method.', 20),
  ('hfcc.commerce_payment_methods.payment_method_type_code.wallet', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'Wallet', 'Wallet payment method.', 30),
  ('hfcc.commerce_payment_methods.payment_method_type_code.manual', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'Manual', 'Manual payment method.', 40),
  ('hfcc.commerce_payment_methods.payment_method_type_code.external', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'External', 'External payment method.', 50),
  ('hfcc.commerce_payment_methods.payment_method_type_code.iap', 'hfcc', 'commerce_payment_methods', 'payment_method_type_code', 'In-App Purchase', 'In-app purchase payment method (Google Play or App Store).', 60),
  ('hfcc.commerce_payment_methods.provider_code.google_play', 'hfcc', 'commerce_payment_methods', 'provider_code', 'Google Play', 'Google Play in-app purchase provider.', 60),
  ('hfcc.commerce_payment_methods.provider_code.app_store', 'hfcc', 'commerce_payment_methods', 'provider_code', 'App Store', 'Apple App Store in-app purchase provider.', 70),
  ('hfcc.commerce_payment_intents.provider_code.stripe', 'hfcc', 'commerce_payment_intents', 'provider_code', 'Stripe', 'Stripe payment provider.', 10),
  ('hfcc.commerce_payment_intents.provider_code.paypal', 'hfcc', 'commerce_payment_intents', 'provider_code', 'PayPal', 'PayPal payment provider.', 20),
  ('hfcc.commerce_payment_intents.provider_code.manual', 'hfcc', 'commerce_payment_intents', 'provider_code', 'Manual', 'Manual payment provider.', 30),
  ('hfcc.commerce_payment_intents.provider_code.external', 'hfcc', 'commerce_payment_intents', 'provider_code', 'External', 'External payment provider.', 40),
  ('hfcc.commerce_payment_intents.provider_code.ledger', 'hfcc', 'commerce_payment_intents', 'provider_code', 'Ledger', 'Internal ledger balance payment provider.', 50),
  ('hfcc.commerce_payment_intents.provider_code.google_play', 'hfcc', 'commerce_payment_intents', 'provider_code', 'Google Play', 'Google Play in-app purchase provider.', 60),
  ('hfcc.commerce_payment_intents.provider_code.app_store', 'hfcc', 'commerce_payment_intents', 'provider_code', 'App Store', 'Apple App Store in-app purchase provider.', 70),
  ('hfcc.commerce_payment_intents.status_code.pending', 'hfcc', 'commerce_payment_intents', 'status_code', 'Pending', 'Payment intent is pending.', 10),
  ('hfcc.commerce_payment_intents.status_code.requires_action', 'hfcc', 'commerce_payment_intents', 'status_code', 'Requires action', 'Payment intent requires customer action.', 20),
  ('hfcc.commerce_payment_intents.status_code.processing', 'hfcc', 'commerce_payment_intents', 'status_code', 'Processing', 'Payment intent is processing.', 30),
  ('hfcc.commerce_payment_intents.status_code.succeeded', 'hfcc', 'commerce_payment_intents', 'status_code', 'Succeeded', 'Payment intent succeeded.', 40),
  ('hfcc.commerce_payment_intents.status_code.failed', 'hfcc', 'commerce_payment_intents', 'status_code', 'Failed', 'Payment intent failed.', 50),
  ('hfcc.commerce_payment_intents.status_code.cancelled', 'hfcc', 'commerce_payment_intents', 'status_code', 'Cancelled', 'Payment intent was cancelled.', 60),
  ('hfcc.commerce_payment_intents.status_code.refunded', 'hfcc', 'commerce_payment_intents', 'status_code', 'Refunded', 'Payment intent was refunded.', 70),

  -- Media
  ('hfcc.media.owner_type.user', 'hfcc', 'media', 'owner_type', 'User', 'Media owned by a HFCC user.', 10),
  ('hfcc.media.owner_type.system', 'hfcc', 'media', 'owner_type', 'System', 'Media owned by system service logic.', 20),
  ('hfcc.media.owner_type.shop', 'hfcc', 'media', 'owner_type', 'Shop', 'Media owned by a shop.', 30),
  ('hfcc.media.owner_type.org', 'hfcc', 'media', 'owner_type', 'Organization', 'Media owned by an organization.', 40),
  ('hfcc.media.owner_type.app', 'hfcc', 'media', 'owner_type', 'App', 'Media owned by an app namespace.', 50),
  ('hfcc.media.media_type_code.image', 'hfcc', 'media', 'media_type_code', 'Image', 'Image media.', 10),
  ('hfcc.media.media_type_code.video', 'hfcc', 'media', 'media_type_code', 'Video', 'Video media.', 20),
  ('hfcc.media.media_type_code.audio', 'hfcc', 'media', 'media_type_code', 'Audio', 'Audio media.', 30),
  ('hfcc.media.media_type_code.model_3d', 'hfcc', 'media', 'media_type_code', '3D Model', '3D model media (glb, gltf, usdz, fbx, obj, ply, stl, etc.).', 35),
  ('hfcc.media.media_type_code.document', 'hfcc', 'media', 'media_type_code', 'Document', 'Document media (pdf, doc, docx, odt, txt, rtf, etc.).', 40),
  ('hfcc.media.media_type_code.spreadsheet', 'hfcc', 'media', 'media_type_code', 'Spreadsheet', 'Spreadsheet media (xls, xlsx, ods, numbers, etc.).', 41),
  ('hfcc.media.media_type_code.presentation', 'hfcc', 'media', 'media_type_code', 'Presentation', 'Presentation media (ppt, pptx, odp, key, etc.).', 42),
  ('hfcc.media.media_type_code.archive', 'hfcc', 'media', 'media_type_code', 'Archive', 'Archive media (zip, tar, gz, 7z, rar, etc.).', 43),
  ('hfcc.media.media_type_code.code', 'hfcc', 'media', 'media_type_code', 'Code', 'Source code media (js, ts, py, c, cpp, java, sh, etc.).', 44),
  ('hfcc.media.media_type_code.font', 'hfcc', 'media', 'media_type_code', 'Font', 'Font media (ttf, otf, woff, woff2, eot, etc.).', 45),
  ('hfcc.media.media_type_code.data', 'hfcc', 'media', 'media_type_code', 'Data', 'Structured data media (json, csv, tsv, xml, yaml, parquet, etc.).', 46),
  ('hfcc.media.media_type_code.executable', 'hfcc', 'media', 'media_type_code', 'Executable', 'Executable or installer media (exe, msi, dmg, deb, rpm, apk, etc.).', 47),
  ('hfcc.media.media_type_code.other', 'hfcc', 'media', 'media_type_code', 'Other', 'Other media (none of the above).', 50),
  ('hfcc.media.storage_provider_code.supabase', 'hfcc', 'media', 'storage_provider_code', 'Supabase Storage', 'Supabase Storage object.', 10),
  ('hfcc.media.storage_provider_code.s3', 'hfcc', 'media', 'storage_provider_code', 'S3', 'Amazon S3 compatible object.', 20),
  ('hfcc.media.storage_provider_code.gcs', 'hfcc', 'media', 'storage_provider_code', 'Google Cloud Storage', 'Google Cloud Storage object.', 30),
  ('hfcc.media.storage_provider_code.cloudflare', 'hfcc', 'media', 'storage_provider_code', 'Cloudflare R2', 'Cloudflare R2 object.', 40),
  ('hfcc.media.storage_provider_code.external', 'hfcc', 'media', 'storage_provider_code', 'External', 'Externally stored object.', 50),
  ('hfcc.media_relations.role_code.avatar', 'hfcc', 'media_relations', 'role_code', 'Avatar', 'Avatar relation.', 10),
  ('hfcc.media_relations.role_code.primary', 'hfcc', 'media_relations', 'role_code', 'Primary', 'Primary media relation.', 20),
  ('hfcc.media_relations.role_code.cover', 'hfcc', 'media_relations', 'role_code', 'Cover', 'Cover media relation.', 30),
  ('hfcc.media_relations.role_code.gallery', 'hfcc', 'media_relations', 'role_code', 'Gallery', 'Gallery media relation.', 40),
  ('hfcc.media_relations.role_code.thumbnail', 'hfcc', 'media_relations', 'role_code', 'Thumbnail', 'Thumbnail relation.', 50),
  ('hfcc.media_relations.role_code.attachment', 'hfcc', 'media_relations', 'role_code', 'Attachment', 'Attachment relation.', 60),

  -- Activity and audit
  ('hfcc.activity_logs.action_code.request.created', 'hfcc', 'activity_logs', 'action_code', 'Request created', 'A user or system request was created.', 10),
  ('hfcc.activity_logs.action_code.user.login', 'hfcc', 'activity_logs', 'action_code', 'User login', 'A user logged in.', 20),
  ('hfcc.activity_logs.action_code.user.logout', 'hfcc', 'activity_logs', 'action_code', 'User logout', 'A user logged out.', 30),
  ('hfcc.activity_logs.action_code.user.updated', 'hfcc', 'activity_logs', 'action_code', 'User updated', 'A HFCC user row was updated.', 40),
  ('hfcc.activity_logs.action_code.subscription.changed', 'hfcc', 'activity_logs', 'action_code', 'Subscription changed', 'A subscription changed.', 50),
  ('hfcc.activity_logs.action_code.subscription.started', 'hfcc', 'activity_logs', 'action_code', 'Subscription started', 'A subscription started.', 60),
  ('hfcc.activity_logs.action_code.subscription.cancelled', 'hfcc', 'activity_logs', 'action_code', 'Subscription cancelled', 'A subscription was cancelled.', 70),
  ('hfcc.activity_logs.action_code.promotion.used', 'hfcc', 'activity_logs', 'action_code', 'Promotion used', 'A promotion was used.', 80),
  ('hfcc.activity_logs.action_code.message.sent', 'hfcc', 'activity_logs', 'action_code', 'Message sent', 'A message was sent.', 90),
  ('hfcc.activity_logs.action_code.type_applied', 'hfcc', 'activity_logs', 'action_code', 'Type applied', 'A configured type code was applied to a row.', 100),
  ('hfcc.activity_logs.source_type.user', 'hfcc', 'activity_logs', 'source_type', 'User', 'Activity sourced from a user action.', 10),
  ('hfcc.activity_logs.source_type.job', 'hfcc', 'activity_logs', 'source_type', 'Job', 'Activity sourced from a job.', 20),
  ('hfcc.activity_logs.source_type.subscription', 'hfcc', 'activity_logs', 'source_type', 'Subscription', 'Activity sourced from subscription service logic.', 30),
  ('hfcc.activity_logs.source_type.promotion_usage', 'hfcc', 'activity_logs', 'source_type', 'Promotion usage', 'Activity sourced from promotion usage.', 40),
  ('hfcc.activity_logs.source_type.commerce_order', 'hfcc', 'activity_logs', 'source_type', 'Commerce order', 'Activity sourced from commerce order service logic.', 50),
  ('hfcc.activity_logs.source_type.type_dispatch', 'hfcc', 'activity_logs', 'source_type', 'Type dispatch', 'Activity sourced from type-code dispatch.', 60),
  ('hfcc.audit_logs.action_code.insert', 'hfcc', 'audit_logs', 'action_code', 'Insert', 'A row was inserted.', 10),
  ('hfcc.audit_logs.action_code.update', 'hfcc', 'audit_logs', 'action_code', 'Update', 'A row was updated.', 20),
  ('hfcc.audit_logs.action_code.delete', 'hfcc', 'audit_logs', 'action_code', 'Delete', 'A row was deleted.', 30),
  ('hfcc.audit_logs.action_code.validation_failed', 'hfcc', 'audit_logs', 'action_code', 'Validation failed', 'A unified validation trigger rejected a row change.', 40),
  ('hfcc.audit_logs.action_code.event_handler', 'hfcc', 'audit_logs', 'action_code', 'Event handler', 'An event handler dispatch attempt completed or failed.', 50),
  ('hfcc.audit_logs.action_code.job_handler', 'hfcc', 'audit_logs', 'action_code', 'Job handler', 'A job handler dispatch attempt completed or failed.', 60),
  ('hfcc.audit_logs.action_code.type_dispatch', 'hfcc', 'audit_logs', 'action_code', 'Type dispatch', 'A configured type dispatch attempt completed or failed.', 70)
on conflict (code) do nothing;

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_job_subscription_maintenance_daily',
      'payload_key', 'handle_job_subscription_maintenance_daily'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.jobs.job_code.subscription.maintenance_daily';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_job_subscription_expire',
      'payload_key', 'handle_job_subscription_expire'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.jobs.job_code.subscription.expire';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_job_subscription_activate',
      'payload_key', 'handle_job_subscription_activate'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.jobs.job_code.subscription.activate';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_job_subscription_renewal_notice',
      'payload_key', 'handle_job_subscription_renewal_notice'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.jobs.job_code.subscription.renewal_notice';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_outgoing_message_send_requested',
      'payload_key', 'handle_outgoing_message_send_requested'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.events_outbox.event_code.message.send_requested';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_outgoing_message_escalation_due',
      'payload_key', 'handle_outgoing_message_escalation_due'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.events_outbox.event_code.message.escalation_due';

update hfcc.types
set invoke_functions = jsonb_build_array(jsonb_build_object(
      'function_name', 'handle_subscription_renewal_notice_requested',
      'payload_key', 'handle_subscription_renewal_notice_requested'
    )),
    log_audit = true,
    updated_at = now()
where code = 'hfcc.events_outbox.event_code.subscription.renewal_notice_requested';

update hfcc.types
set metadata = metadata || '{
  "channel_code": "hfcc.outgoing_messages.channel_code.inapp",
  "subject_template": "Your subscription renews soon",
  "body_template": "Hi {{display_name}}, your subscription renews on {{renewal_date}}.",
  "required_payload_keys": ["display_name", "renewal_date"],
  "default_provider_code": "hfcc.outgoing_messages.provider_code.inapp",
  "escalation": {
    "steps": [
      {
        "channel_code": "hfcc.outgoing_messages.channel_code.push",
        "provider_code": "hfcc.outgoing_messages.provider_code.fcm",
        "delay_seconds": 10
      },
      {
        "channel_code": "hfcc.outgoing_messages.channel_code.sms",
        "provider_code": "hfcc.outgoing_messages.provider_code.twilio",
        "delay_seconds": 60,
        "recipient_payload_key": "sms_recipient"
      },
      {
        "channel_code": "hfcc.outgoing_messages.channel_code.email",
        "provider_code": "hfcc.outgoing_messages.provider_code.smtp",
        "delay_seconds": 60,
        "recipient_payload_key": "email_recipient"
      }
    ]
  }
}'::jsonb,
    updated_at = now()
where code = 'hfcc.outgoing_messages.template_code.subscription_renewal_notice';

-- ---------------------------------------------------------------------------
-- JSON schema validation
-- ---------------------------------------------------------------------------

create table if not exists hfcc.json_schemas (
  id uuid primary key default extensions.gen_random_uuid(),
  entity text not null,
  field text not null default 'attributes',
  version integer not null default 1,
  json_schema jsonb not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint json_schemas_version_check check (version > 0),
  constraint json_schemas_json_schema_object_check check (jsonb_typeof(json_schema) = 'object'),
  constraint json_schemas_unique_version unique (entity, field, version)
);

create index if not exists json_schemas_active_idx
  on hfcc.json_schemas (entity, field, is_active, version desc);

comment on table hfcc.json_schemas is
  'Stores JSON Schema-like validators for reusable JSON and JSONB fields.';

insert into hfcc.json_schemas (entity, field, version, json_schema)
values
  ('types', 'invoke_functions', 1, '{"type": "array"}'::jsonb),
  ('types', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('json_schemas', 'json_schema', 1, '{"type": "object"}'::jsonb),
  ('users', 'attributes', 1, '{"type": "object"}'::jsonb),
  ('media', 'attributes', 1, '{"type": "object"}'::jsonb),
  ('media', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('settings', 'value', 1, '{"type": "object"}'::jsonb),
  ('events_outbox', 'payload', 1, '{"type": "object"}'::jsonb),
  ('events_outbox', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('events_inbox', 'payload', 1, '{"type": "object"}'::jsonb),
  ('events_inbox', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('jobs', 'payload', 1, '{"type": "object"}'::jsonb),
  ('ledger_currencies', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('ledger_accounts', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('ledger_transactions', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('subscriptions', 'attributes', 1, '{"type": "object"}'::jsonb),
  ('ledger_wallet_grants', 'metadata', 1, '{"type": "object"}'::jsonb),
  (
    'promotions',
    'rules',
    1,
    '{
      "type": "object",
      "properties": {
        "ledger_wallet_grants": {
          "type": "array",
          "description": "Ledger wallet grant definitions applied when a promotion is used.",
          "items": {
            "type": "object",
            "required": ["currency_code", "amount"],
            "properties": {
              "currency_code": {
                "type": "string",
                "description": "ledger_currencies.code to credit to the user wallet."
              },
              "key": {
                "type": "string",
                "description": "Optional stable grant key. Defaults to currency_code plus the grant position."
              },
              "amount": {
                "type": "number",
                "exclusiveMinimum": 0,
                "description": "Positive amount credited by the promotion."
              },
              "recharge_interval": {
                "type": "string",
                "enum": ["once", "day", "week", "month", "year"],
                "default": "once",
                "description": "How often the grant can be re-applied by grant processors."
              },
              "expire_on_next_charge": {
                "type": "boolean",
                "default": false,
                "description": "When true, unused granted amount is deducted before the next recharge."
              },
              "source_account_id": {
                "type": "string",
                "format": "uuid",
                "description": "Optional ledger account funding this grant. If omitted, the promotion/system account for the currency is used."
              }
            },
            "additionalProperties": false
          }
        },
        "discount": {
          "type": "object",
          "description": "Optional discount behavior such as percent or fixed amount. App logic decides how these rules are interpreted."
        },
        "eligibility": {
          "type": "object",
          "description": "Optional eligibility rules such as first-order-only, product filters, user segment filters, or minimum totals."
        },
        "limits": {
          "type": "object",
          "description": "Optional behavior limits beyond max_uses and per_user_limit, such as per-order limits or rule-specific caps."
        }
      },
      "additionalProperties": false
    }'::jsonb
  ),
  ('promotions', 'attributes', 1, '{"type": "object"}'::jsonb),
  (
    'commerce_products',
    'attributes',
    1,
    '{
      "type": "object",
      "properties": {
        "subscription": {
          "type": "boolean",
          "description": "Whether this product represents a recurring subscription plan."
        },
        "billing_interval": {
          "type": "string",
          "enum": ["day", "week", "month", "year"],
          "description": "Billing cadence for subscription products. Maps to commerce_orders.billing_interval_code suffix."
        }
      },
      "additionalProperties": true
    }'::jsonb
  ),
  ('commerce_products', 'rules', 1, '{"type": "object"}'::jsonb),
  (
    'commerce_products',
    'entitlements',
    1,
    '{
      "type": "object",
      "properties": {
        "ledger_wallet_grants": {
          "type": "array",
          "description": "Ledger wallet grant definitions applied when a commerce order item is fulfilled.",
          "items": {
            "type": "object",
            "required": ["currency_code", "amount"],
            "properties": {
              "currency_code": {
                "type": "string",
                "description": "ledger_currencies.code to credit to the buyer wallet."
              },
              "key": {
                "type": "string",
                "description": "Optional stable grant key. Defaults to currency_code plus the grant position."
              },
              "amount": {
                "type": "number",
                "exclusiveMinimum": 0,
                "description": "Positive amount credited by the product."
              },
              "recharge_interval": {
                "type": "string",
                "enum": ["once", "day", "week", "month", "year"],
                "default": "once",
                "description": "How often the grant can be re-applied by grant processors."
              },
              "expire_on_next_charge": {
                "type": "boolean",
                "default": false,
                "description": "When true, unused granted amount is deducted before the next recharge."
              },
              "source_account_id": {
                "type": "string",
                "format": "uuid",
                "description": "Optional ledger account funding this grant. If omitted, app logic should choose the system account for the currency."
              }
            },
            "additionalProperties": false
          }
        }
      },
      "additionalProperties": false
    }'::jsonb
  ),
  ('commerce_products', 'payload', 1, '{"type": "object"}'::jsonb),
  ('commerce_products', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('commerce_orders', 'billing_info', 1, '{"type": "object"}'::jsonb),
  ('commerce_orders', 'shipping_info', 1, '{"type": "object"}'::jsonb),
  ('commerce_orders', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('commerce_order_items', 'rules_snapshot', 1, '{"type": "object"}'::jsonb),
  ('commerce_order_items', 'entitlements_snapshot', 1, '{"type": "object"}'::jsonb),
  (
    'commerce_order_items',
    'payload_snapshot',
    1,
    '{
      "type": "object",
      "required": ["product"],
      "properties": {
        "product": {
          "type": "object",
          "description": "Product detail snapshot captured at purchase time. Expected keys include name and product_type_code. The canonical product relation is commerce_order_items.product_id, and billing interval is stored on the commerce order."
        }
      },
      "additionalProperties": true
    }'::jsonb
  ),
  ('commerce_order_items', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('commerce_payment_methods', 'billing_info', 1, '{"type": "object"}'::jsonb),
  ('commerce_payment_methods', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('commerce_payment_intents', 'request_payload', 1, '{"type": "object"}'::jsonb),
  ('commerce_payment_intents', 'response_payload', 1, '{"type": "object"}'::jsonb),
  ('commerce_payment_intents', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('devices', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('outgoing_messages', 'payload', 1, '{"type": "object"}'::jsonb),
  ('outgoing_messages', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('activity_logs', 'metadata', 1, '{"type": "object"}'::jsonb),
  ('audit_logs', 'old_data', 1, '{"type": "object"}'::jsonb),
  ('audit_logs', 'new_data', 1, '{"type": "object"}'::jsonb),
  ('audit_logs', 'metadata', 1, '{"type": "object"}'::jsonb)
on conflict (entity, field, version) do nothing;

-- ---------------------------------------------------------------------------
-- Users and media foundations
-- ---------------------------------------------------------------------------

create table if not exists hfcc.users (
  id uuid primary key default extensions.gen_random_uuid(),
  display_name text,
  role_code text not null default 'hfcc.users.role_code.user',
  avatar_media_id uuid,
  attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint users_attributes_object_check check (jsonb_typeof(attributes) = 'object')
);

comment on table hfcc.users is
  'Application user row. Supabase Auth inserts are mirrored by trigger with the same id as auth.users.id, but hfcc.users intentionally does not FK to auth.users.';

create table if not exists hfcc.media (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_type text not null,
  owner_id uuid,
  file_name text,
  mime_type text,
  media_type_code text not null,
  storage_provider_code text not null default 'hfcc.media.storage_provider_code.supabase',
  storage_key text not null,
  file_size bigint,
  width integer,
  height integer,
  duration_seconds numeric,
  attributes jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint media_file_size_check check (file_size is null or file_size >= 0),
  constraint media_dimensions_check check (
    (width is null or width > 0)
    and (height is null or height > 0)
    and (duration_seconds is null or duration_seconds >= 0)
  ),
  constraint media_attributes_object_check check (jsonb_typeof(attributes) = 'object'),
  constraint media_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists media_owner_idx on hfcc.media (owner_type, owner_id);
create index if not exists media_media_type_idx on hfcc.media (media_type_code);
create unique index if not exists media_storage_unique_idx on hfcc.media (storage_provider_code, storage_key);

comment on table hfcc.media is
  'Generic media objects backed by Supabase Storage, S3, or external providers.';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'users_avatar_media_id_fkey'
      and conrelid = 'hfcc.users'::regclass
  ) then
    alter table hfcc.users
      add constraint users_avatar_media_id_fkey
      foreign key (avatar_media_id) references hfcc.media(id) on delete set null;
  end if;
end;
$$;

create table if not exists hfcc.media_relations (
  id uuid primary key default extensions.gen_random_uuid(),
  media_id uuid not null references hfcc.media(id) on delete cascade,
  entity text not null,
  entity_id uuid not null,
  role_code text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint media_relations_unique_role unique (media_id, entity, entity_id, role_code)
);

create index if not exists media_relations_entity_idx on hfcc.media_relations (entity, entity_id, role_code, sort_order);

comment on table hfcc.media_relations is
  'Polymorphic links from media objects to reusable or app-specific entities.';

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

create table if not exists hfcc.settings (
  id uuid primary key default extensions.gen_random_uuid(),
  scope_type text not null,
  scope_id uuid,
  key text not null,
  value jsonb not null default '{}'::jsonb,
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint settings_key_not_blank_check check (length(btrim(key)) > 0),
  constraint settings_scope_unique unique nulls not distinct (scope_type, scope_id, key)
);

create index if not exists settings_scope_idx on hfcc.settings (scope_type, scope_id, key);
create index if not exists settings_public_idx on hfcc.settings (is_public) where is_public;

comment on table hfcc.settings is
  'Scoped JSON settings. Public settings can be read through RLS; writes are owner or service controlled.';

create or replace function hfcc.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_display_name text;
  v_attributes jsonb;
begin
  v_display_name := nullif(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name'
  ), '');

  v_attributes := case
    when jsonb_typeof(new.raw_user_meta_data -> 'attributes') = 'object'
      then new.raw_user_meta_data -> 'attributes'
    else '{}'::jsonb
  end;

  insert into hfcc.users (id, display_name, attributes)
  values (new.id, v_display_name, v_attributes)
  on conflict (id) do nothing;

  perform hfcc.ensure_user_ledger_accounts(new.id);

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- ensure_hfcc_user — idempotent row in hfcc.users
--
-- Guarantees an hfcc.users row exists for the given auth.users id.
-- Safe to call repeatedly; no-ops if the row already exists.
-- Needed when code runs for users created before the
-- on_auth_user_created trigger was installed (e.g. pre-HFCC users).
-- ---------------------------------------------------------------------------

create or replace function hfcc.ensure_hfcc_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if p_user_id is null then
    raise exception 'p_user_id is required' using errcode = '22023';
  end if;

  insert into hfcc.users (id)
  values (p_user_id)
  on conflict (id) do nothing;
end;
$$;

-- Do not use COMMENT ON TRIGGER for auth.users in hosted Supabase. The auth
-- table is owned by Supabase's internal auth role, so owner-only metadata
-- operations can fail even when the trigger itself is allowed. Also avoid
-- CREATE OR REPLACE TRIGGER here because replacing an existing trigger on
-- auth.users can require relation ownership. If the trigger already exists,
-- it will continue to call the replaced handle_new_auth_user() function.
do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'auth.users'::regclass
      and tgname = 'on_auth_user_created'
      and not tgisinternal
  ) then
    execute 'create trigger on_auth_user_created after insert on auth.users for each row execute function hfcc.handle_new_auth_user()';
  end if;
end;
$$;

-- Backfill users for projects that already have Supabase Auth users before
-- this migration is applied. New users are handled by on_auth_user_created.
insert into hfcc.users (id, display_name, attributes)
select
  u.id,
  nullif(coalesce(
    u.raw_user_meta_data ->> 'display_name',
    u.raw_user_meta_data ->> 'full_name',
    u.raw_user_meta_data ->> 'name'
  ), ''),
  case
    when jsonb_typeof(u.raw_user_meta_data -> 'attributes') = 'object'
      then u.raw_user_meta_data -> 'attributes'
    else '{}'::jsonb
  end
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Outbox, inbox, and scheduled jobs
-- ---------------------------------------------------------------------------

create table if not exists hfcc.events_outbox (
  id uuid primary key default extensions.gen_random_uuid(),
  event_code text not null,
  source_type text,
  source_id uuid,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  status_code text not null default 'hfcc.events_outbox.status_code.pending',
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  run_after timestamptz not null default now(),
  locked_at timestamptz,
  processed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint outbox_payload_object_check check (jsonb_typeof(payload) = 'object'),
  constraint outbox_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint outbox_attempts_check check (attempt_count >= 0 and max_attempts > 0 and attempt_count <= max_attempts)
);

create index if not exists outbox_due_idx
  on hfcc.events_outbox (status_code, run_after)
  where processed_at is null;
create index if not exists outbox_source_idx on hfcc.events_outbox (source_type, source_id);

comment on table hfcc.events_outbox is
  'Transactional outbox for integrations and async side effects.';

create table if not exists hfcc.events_inbox (
  id uuid primary key default extensions.gen_random_uuid(),
  source_code text not null,
  external_event_id text not null,
  event_code text not null,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  status_code text not null default 'hfcc.events_inbox.status_code.pending',
  processed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inbox_payload_object_check check (jsonb_typeof(payload) = 'object'),
  constraint inbox_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint inbox_source_external_unique unique (source_code, external_event_id)
);

create index if not exists inbox_due_idx on hfcc.events_inbox (status_code, created_at);
create index if not exists inbox_event_code_idx on hfcc.events_inbox (event_code, created_at desc);

comment on table hfcc.events_inbox is
  'Idempotent inbox for externally sourced events.';

create table if not exists hfcc.jobs (
  id uuid primary key default extensions.gen_random_uuid(),
  job_code text not null,
  source_type text,
  source_id uuid,
  payload jsonb not null default '{}'::jsonb,
  status_code text not null default 'hfcc.jobs.status_code.pending',
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  run_after timestamptz not null default now(),
  locked_at timestamptz,
  processed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint jobs_payload_object_check check (jsonb_typeof(payload) = 'object'),
  constraint jobs_attempts_check check (attempt_count >= 0 and max_attempts > 0 and attempt_count <= max_attempts)
);

create index if not exists jobs_due_idx
  on hfcc.jobs (status_code, run_after)
  where processed_at is null;
create index if not exists jobs_source_idx on hfcc.jobs (source_type, source_id);

comment on table hfcc.jobs is
  'Scheduled or deferred internal work claimed by pg_cron or external workers.';

create or replace function hfcc.enqueue_outbox_event(
  p_event_code text,
  p_source_type text default null,
  p_source_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb,
  p_run_after timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_outbox_event_id uuid;
begin
  insert into hfcc.events_outbox (
    event_code,
    source_type,
    source_id,
    payload,
    metadata,
    run_after
  )
  values (
    p_event_code,
    p_source_type,
    p_source_id,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb),
    coalesce(p_run_after, now())
  )
  returning id into v_outbox_event_id;

  return v_outbox_event_id;
end;
$$;

create or replace function hfcc.claim_due_jobs(p_limit integer default 100)
returns setof hfcc.jobs
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if p_limit is null or p_limit < 1 then
    raise exception 'p_limit must be greater than zero' using errcode = '22023';
  end if;

  return query
  with due_jobs as (
    select j.id
    from hfcc.jobs j
    join hfcc.types t
      on t.code = j.job_code
     and t.schema = 'hfcc'
     and t.entity = 'jobs'
     and t.field = 'job_code'
     and t.is_active
     and jsonb_array_length(t.invoke_functions) > 0
    where j.status_code = 'hfcc.jobs.status_code.pending'
      and j.run_after <= now()
      and j.processed_at is null
      and j.attempt_count < j.max_attempts
    order by j.run_after, j.created_at
    limit p_limit
    for update skip locked
  )
  update hfcc.jobs j
  set status_code = 'hfcc.jobs.status_code.processing',
      attempt_count = j.attempt_count + 1,
      locked_at = now(),
      updated_at = now()
  from due_jobs
  where j.id = due_jobs.id
  returning j.*;
end;
$$;

create or replace function hfcc.handle_job_subscription_maintenance_daily(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription_id uuid;
begin
  v_subscription_id := (p_payload ->> 'subscription_id')::uuid;

  if v_subscription_id is null then
    raise exception 'Job payload requires subscription_id'
      using errcode = '22023';
  end if;

  return hfcc.process_subscription_maintenance(v_subscription_id, now());
end;
$$;

create or replace function hfcc.handle_job_subscription_expire(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription_id uuid;
begin
  v_subscription_id := (p_payload ->> 'subscription_id')::uuid;

  if v_subscription_id is null then
    raise exception 'Job payload requires subscription_id'
      using errcode = '22023';
  end if;

  return hfcc.process_subscription_maintenance(v_subscription_id, now());
end;
$$;

create or replace function hfcc.handle_job_subscription_activate(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription_id uuid;
begin
  v_subscription_id := (p_payload ->> 'subscription_id')::uuid;

  if v_subscription_id is null then
    raise exception 'Job payload requires subscription_id'
      using errcode = '22023';
  end if;

  return hfcc.activate_scheduled_subscription(v_subscription_id, now());
end;
$$;

create or replace function hfcc.handle_job_subscription_renewal_notice(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription_id uuid;
  v_outbox_event_id uuid;
begin
  v_subscription_id := (p_payload ->> 'subscription_id')::uuid;

  if v_subscription_id is null then
    raise exception 'Job payload requires subscription_id'
      using errcode = '22023';
  end if;

  v_outbox_event_id := hfcc.enqueue_subscription_renewal_notice(v_subscription_id, now());

  return jsonb_build_object(
    'subscription_id', v_subscription_id,
    'outbox_event_id', v_outbox_event_id
  );
end;
$$;

create or replace function hfcc.process_due_jobs(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_claimed integer;
begin
  if p_limit is null or p_limit < 1 then
    raise exception 'p_limit must be greater than zero'
      using errcode = '22023';
  end if;

  select count(*)
  into v_claimed
  from hfcc.claim_due_jobs(p_limit);

  return jsonb_build_object(
    'ok', true,
    'claimed', v_claimed,
    'dispatcher', 'core_after_type_dispatch'
  );
end;
$$;

create or replace function hfcc.claim_due_events_outbox(p_limit integer default 100)
returns setof hfcc.events_outbox
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if p_limit is null or p_limit < 1 then
    raise exception 'p_limit must be greater than zero' using errcode = '22023';
  end if;

  return query
  with due_events as (
    select o.id
    from hfcc.events_outbox o
    join hfcc.types t
      on t.code = o.event_code
     and t.schema = 'hfcc'
     and t.entity = 'events_outbox'
     and t.field = 'event_code'
     and t.is_active
     and jsonb_array_length(t.invoke_functions) > 0
    where o.status_code = 'hfcc.events_outbox.status_code.pending'
      and o.run_after <= now()
      and o.processed_at is null
      and o.attempt_count < o.max_attempts
    order by o.run_after, o.created_at
    limit p_limit
    for update skip locked
  )
  update hfcc.events_outbox o
  set status_code = 'hfcc.events_outbox.status_code.processing',
      attempt_count = o.attempt_count + 1,
      locked_at = now(),
      updated_at = now()
  from due_events
  where o.id = due_events.id
  returning o.*;
end;
$$;

create or replace function hfcc.process_due_events_outbox(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_claimed integer;
begin
  if p_limit is null or p_limit < 1 then
    raise exception 'p_limit must be greater than zero'
      using errcode = '22023';
  end if;

  select count(*)
  into v_claimed
  from hfcc.claim_due_events_outbox(p_limit);

  return jsonb_build_object(
    'ok', true,
    'claimed', v_claimed,
    'dispatcher', 'core_after_type_dispatch'
  );
end;
$$;

create or replace function hfcc.retry_stuck_jobs(
  p_stale_after interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_count integer;
begin
  update hfcc.jobs j
  set status_code = 'hfcc.jobs.status_code.pending',
      locked_at = null,
      error_message = null,
      updated_at = now()
  where j.status_code = 'hfcc.jobs.status_code.processing'
    and j.locked_at is not null
    and j.locked_at < now() - p_stale_after
    and j.attempt_count < j.max_attempts;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function hfcc.retry_stuck_events_outbox(
  p_stale_after interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_count integer;
begin
  update hfcc.events_outbox o
  set status_code = 'hfcc.events_outbox.status_code.pending',
      locked_at = null,
      error_message = null,
      updated_at = now()
  where o.status_code = 'hfcc.events_outbox.status_code.processing'
    and o.locked_at is not null
    and o.locked_at < now() - p_stale_after
    and o.attempt_count < o.max_attempts;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------

create table if not exists hfcc.ledger_currencies (
  code text primary key,
  name text not null,
  type_code text not null,
  precision integer not null default 2,
  allow_negative_balance boolean not null default false,
  is_convertible boolean not null default false,
  usd_rate numeric,
  metadata jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ledger_currencies_code_check check (code ~ '^[A-Z][A-Z0-9_]{1,15}$'),
  constraint ledger_currencies_precision_check check (precision >= 0 and precision <= 18),
  constraint ledger_currencies_usd_rate_check check (usd_rate is null or usd_rate > 0),
  constraint ledger_currencies_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

comment on table hfcc.ledger_currencies is
  'Currency catalog for fiat, points, credits, and other money-like units.';

insert into hfcc.ledger_currencies (
  code,
  name,
  type_code,
  precision,
  allow_negative_balance,
  is_convertible,
  usd_rate,
  metadata
)
values
  ('USD', 'US Dollar', 'hfcc.ledger_currencies.type_code.fiat', 2, false, true, 1, '{"iso_4217": true}'::jsonb),
  ('POINTS', 'Loyalty Points', 'hfcc.ledger_currencies.type_code.points', 0, false, false, null, '{"unit": "point"}'::jsonb),
  ('CREDIT', 'App Credits', 'hfcc.ledger_currencies.type_code.credit', 2, false, false, null, '{"unit": "credit"}'::jsonb),
  ('TOKEN', 'App Token', 'hfcc.ledger_currencies.type_code.token', 8, false, false, null, '{"unit": "token"}'::jsonb),
  ('TIER', 'Tier Level', 'hfcc.ledger_currencies.type_code.entitlement', 0, false, false, null, '{"unit": "tier", "semantics": "entitlement_level"}'::jsonb)
on conflict (code) do nothing;

create table if not exists hfcc.ledger_accounts (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_type text not null,
  owner_id uuid,
  currency_code text not null references hfcc.ledger_currencies(code),
  account_type_code text not null,
  name text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ledger_accounts_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint ledger_accounts_owner_unique unique nulls not distinct (
    owner_type,
    owner_id,
    currency_code,
    account_type_code
  )
);

create index if not exists ledger_accounts_owner_idx on hfcc.ledger_accounts (owner_type, owner_id);
create index if not exists ledger_accounts_currency_idx on hfcc.ledger_accounts (currency_code);

comment on table hfcc.ledger_accounts is
  'Double-entry ledger account owned by a typed owner such as user, system, shop, organization, or future app entity.';

create or replace function hfcc.ensure_user_ledger_accounts(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_inserted_count integer;
begin
  if p_user_id is null then
    raise exception 'p_user_id is required' using errcode = '22023';
  end if;

  if not exists (select 1 from hfcc.users p where p.id = p_user_id) then
    raise exception 'User % does not exist', p_user_id using errcode = '23503';
  end if;

  insert into hfcc.ledger_accounts (
    owner_type,
    owner_id,
    currency_code,
    account_type_code,
    name,
    metadata
  )
  select
    'hfcc.ledger_accounts.owner_type.user',
    p_user_id,
    lc.code,
    'hfcc.ledger_accounts.account_type_code.user_wallet',
    lc.code || ' Wallet',
    jsonb_build_object('created_by', 'ensure_user_ledger_accounts')
  from hfcc.ledger_currencies lc
  where lc.is_active
  on conflict (owner_type, owner_id, currency_code, account_type_code) do nothing;

  get diagnostics v_inserted_count = row_count;
  return v_inserted_count;
end;
$$;

-- Backfill wallet accounts for HFCC users that existed before this migration or
-- before new currencies were added.
select hfcc.ensure_user_ledger_accounts(p.id)
from hfcc.users p;

create table if not exists hfcc.ledger_transactions (
  id uuid primary key default extensions.gen_random_uuid(),
  source_type text,
  source_id uuid,
  transaction_code text not null,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  fx_rate_used numeric,
  base_amount_usd numeric,
  created_at timestamptz not null default now(),
  constraint ledger_transactions_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint ledger_transactions_fx_rate_check check (fx_rate_used is null or fx_rate_used > 0),
  constraint ledger_transactions_base_amount_check check (base_amount_usd is null or base_amount_usd >= 0)
);

create index if not exists ledger_transactions_source_idx on hfcc.ledger_transactions (source_type, source_id);
create index if not exists ledger_transactions_code_created_idx on hfcc.ledger_transactions (transaction_code, created_at desc);

comment on table hfcc.ledger_transactions is
  'Ledger transaction header. Entries must balance to zero per currency.';

create table if not exists hfcc.ledger_entries (
  id uuid primary key default extensions.gen_random_uuid(),
  transaction_id uuid not null references hfcc.ledger_transactions(id) on delete cascade,
  account_id uuid not null references hfcc.ledger_accounts(id),
  amount numeric not null,
  created_at timestamptz not null default now(),
  constraint ledger_entries_amount_not_zero_check check (amount <> 0)
);

create index if not exists ledger_entries_transaction_idx on hfcc.ledger_entries (transaction_id);
create index if not exists ledger_entries_account_idx on hfcc.ledger_entries (account_id, created_at desc);

comment on table hfcc.ledger_entries is
  'Double-entry ledger line. Positive amount credits an account; negative amount debits an account.';

create or replace function hfcc.assert_non_system_balances_allowed(p_transaction_id uuid)
returns void
language plpgsql
set search_path = hfcc
as $$
declare
  v_account_id uuid;
  v_currency_code text;
  v_balance numeric;
begin
  if p_transaction_id is null then
    return;
  end if;

  select
    checked.account_id,
    checked.currency_code,
    checked.balance
  into
    v_account_id,
    v_currency_code,
    v_balance
  from (
    select
      la.id as account_id,
      la.currency_code,
      coalesce(sum(all_entries.amount), 0)::numeric as balance
    from hfcc.ledger_entries changed_entries
    join hfcc.ledger_accounts la
      on la.id = changed_entries.account_id
    join hfcc.ledger_currencies lc
      on lc.code = la.currency_code
    left join hfcc.ledger_entries all_entries
      on all_entries.account_id = la.id
    where changed_entries.transaction_id = p_transaction_id
      and la.owner_type <> 'hfcc.ledger_accounts.owner_type.system'
      and not lc.allow_negative_balance
    group by la.id, la.currency_code
    having coalesce(sum(all_entries.amount), 0) < 0
  ) checked
  limit 1;

  if v_account_id is not null then
    raise exception 'Account % cannot have negative % balance: %',
      v_account_id, v_currency_code, v_balance
      using errcode = '23514';
  end if;
end;
$$;

create or replace function hfcc.assert_ledger_transaction_balanced(p_transaction_id uuid)
returns void
language plpgsql
set search_path = hfcc
as $$
declare
  v_entry_count integer;
  v_bad_currency text;
  v_bad_total numeric;
begin
  if p_transaction_id is null then
    return;
  end if;

  if not exists (
    select 1
    from hfcc.ledger_transactions lt
    where lt.id = p_transaction_id
  ) then
    return;
  end if;

  select count(*)
  into v_entry_count
  from hfcc.ledger_entries le
  where le.transaction_id = p_transaction_id;

  if v_entry_count < 2 then
    raise exception 'Ledger transaction % must have at least two entries', p_transaction_id
      using errcode = '23514';
  end if;

  select balances.currency_code, balances.total_amount
  into v_bad_currency, v_bad_total
  from (
    select la.currency_code, sum(le.amount) as total_amount
    from hfcc.ledger_entries le
    join hfcc.ledger_accounts la on la.id = le.account_id
    where le.transaction_id = p_transaction_id
    group by la.currency_code
    having sum(le.amount) <> 0
  ) balances
  limit 1;

  if v_bad_currency is not null then
    raise exception 'Ledger transaction % does not balance for currency %: %',
      p_transaction_id, v_bad_currency, v_bad_total
      using errcode = '23514';
  end if;

  perform hfcc.assert_non_system_balances_allowed(p_transaction_id);
end;
$$;

create or replace function hfcc.validate_ledger_entries_balance_trigger()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if tg_op = 'DELETE' then
    perform hfcc.assert_ledger_transaction_balanced(old.transaction_id);
    return old;
  end if;

  perform hfcc.assert_ledger_transaction_balanced(new.transaction_id);

  if tg_op = 'UPDATE' and old.transaction_id is distinct from new.transaction_id then
    perform hfcc.assert_ledger_transaction_balanced(old.transaction_id);
  end if;

  return new;
end;
$$;

create or replace function hfcc.validate_ledger_transaction_balance_trigger()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  perform hfcc.assert_ledger_transaction_balanced(new.id);
  return new;
end;
$$;

drop trigger if exists ledger_entries_balance_check on hfcc.ledger_entries;
create constraint trigger ledger_entries_balance_check
after insert or update or delete on hfcc.ledger_entries
deferrable initially deferred
for each row execute function hfcc.validate_ledger_entries_balance_trigger();

drop trigger if exists ledger_transactions_balance_check on hfcc.ledger_transactions;
create constraint trigger ledger_transactions_balance_check
after insert or update on hfcc.ledger_transactions
deferrable initially deferred
for each row execute function hfcc.validate_ledger_transaction_balance_trigger();

create or replace function hfcc.create_ledger_transaction(
  p_transaction_code text,
  p_source_id uuid,
  p_entries jsonb,
  p_description text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_transaction_id uuid;
  v_entry jsonb;
  v_account_id uuid;
  v_amount numeric;
begin
  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) < 2 then
    raise exception 'p_entries must be an array with at least two entries'
      using errcode = '22023';
  end if;

  insert into hfcc.ledger_transactions (
    source_type,
    source_id,
    transaction_code,
    description,
    metadata
  )
  values (
    coalesce(nullif(coalesce(p_metadata, '{}'::jsonb) ->> 'source_type', ''), 'hfcc.ledger_transactions.source_type.ledger'),
    p_source_id,
    p_transaction_code,
    p_description,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_transaction_id;

  for v_entry in
    select value from jsonb_array_elements(p_entries)
  loop
    if jsonb_typeof(v_entry) <> 'object'
       or not (v_entry ? 'account_id')
       or not (v_entry ? 'amount') then
      raise exception 'Each ledger entry must include account_id and amount'
        using errcode = '22023';
    end if;

    v_account_id := (v_entry ->> 'account_id')::uuid;
    v_amount := (v_entry ->> 'amount')::numeric;

    if not exists (select 1 from hfcc.ledger_accounts la where la.id = v_account_id) then
      raise exception 'Ledger account % does not exist', v_account_id
        using errcode = '23503';
    end if;

    insert into hfcc.ledger_entries (transaction_id, account_id, amount)
    values (v_transaction_id, v_account_id, v_amount);
  end loop;

  perform hfcc.assert_ledger_transaction_balanced(v_transaction_id);

  return v_transaction_id;
end;
$$;

create or replace function hfcc.spend_user_balance(
  p_user_id uuid,
  p_currency_code text,
  p_amount numeric,
  p_user_account_id uuid default null,
  p_destination_account_id uuid default null,
  p_description text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_user_account_id uuid;
  v_destination_account_id uuid;
  v_transaction_id uuid;
begin
  if p_user_id is null then
    raise exception 'p_user_id is required'
      using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_currency_code, '')), '') is null then
    raise exception 'p_currency_code is required'
      using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'p_amount must be greater than zero'
      using errcode = '22023';
  end if;

  if not exists (select 1 from hfcc.users p where p.id = p_user_id) then
    raise exception 'User % does not exist', p_user_id
      using errcode = '23503';
  end if;

  if not exists (
    select 1
    from hfcc.ledger_currencies lc
    where lc.code = p_currency_code
      and lc.is_active
  ) then
    raise exception 'Currency % does not exist or is inactive', p_currency_code
      using errcode = '23503';
  end if;

  perform hfcc.ensure_user_ledger_accounts(p_user_id);

  if p_user_account_id is not null then
    select la.id
    into v_user_account_id
    from hfcc.ledger_accounts la
    where la.id = p_user_account_id
      and la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = p_user_id
      and la.currency_code = p_currency_code;

    if v_user_account_id is null then
      raise exception 'User account % is not a % wallet for user %',
        p_user_account_id, p_currency_code, p_user_id
        using errcode = '23503';
    end if;
  else
    select la.id
    into v_user_account_id
    from hfcc.ledger_accounts la
    where la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = p_user_id
      and la.currency_code = p_currency_code
      and la.account_type_code = 'hfcc.ledger_accounts.account_type_code.user_wallet'
    limit 1;
  end if;

  if v_user_account_id is null then
    raise exception 'User wallet account for % does not exist', p_currency_code
      using errcode = '23503';
  end if;

  if p_destination_account_id is not null then
    select la.id
    into v_destination_account_id
    from hfcc.ledger_accounts la
    where la.id = p_destination_account_id
      and la.currency_code = p_currency_code;

    if v_destination_account_id is null then
      raise exception 'Destination account % does not exist for currency %',
        p_destination_account_id, p_currency_code
        using errcode = '23503';
    end if;
  else
    select la.id
    into v_destination_account_id
    from hfcc.ledger_accounts la
    where la.owner_type = 'hfcc.ledger_accounts.owner_type.system'
      and la.currency_code = p_currency_code
      and la.account_type_code in (
        'hfcc.ledger_accounts.account_type_code.system',
        'hfcc.ledger_accounts.account_type_code.revenue'
      )
    order by case la.account_type_code
      when 'hfcc.ledger_accounts.account_type_code.system' then 1
      when 'hfcc.ledger_accounts.account_type_code.revenue' then 2
      else 3
    end
    limit 1;
  end if;

  if v_destination_account_id is null then
    raise exception 'No system destination account found for currency %', p_currency_code
      using errcode = '23503';
  end if;

  v_transaction_id := hfcc.create_ledger_transaction(
    'hfcc.ledger_transactions.transaction_code.purchase',
    null,
    jsonb_build_array(
      jsonb_build_object('account_id', v_user_account_id, 'amount', -p_amount),
      jsonb_build_object('account_id', v_destination_account_id, 'amount', p_amount)
    ),
    coalesce(p_description, 'User balance spend'),
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'kind', 'user_spend',
      'user_id', p_user_id,
      'currency_code', p_currency_code,
      'amount', p_amount,
      'user_account_id', v_user_account_id,
      'destination_account_id', v_destination_account_id
    )
  );

  return v_transaction_id;
end;
$$;

create or replace view hfcc.ledger_balances
with (security_invoker = true)
as
select
  la.id as account_id,
  la.currency_code,
  coalesce(sum(le.amount), 0)::numeric as balance
from hfcc.ledger_accounts la
left join hfcc.ledger_entries le on le.account_id = la.id
group by la.id, la.currency_code;

comment on view hfcc.ledger_balances is
  'Current account balances derived from ledger entries. Uses security_invoker so underlying RLS applies.';

-- ---------------------------------------------------------------------------
-- Subscription and loyalty
-- ---------------------------------------------------------------------------

create table if not exists hfcc.subscriptions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references hfcc.users(id) on delete cascade,
  payment_method_id uuid,
  billing_interval_code text not null,
  initial_order_id uuid,
  latest_order_id uuid,
  status_code text not null default 'hfcc.subscriptions.status_code.draft',
  period_start timestamptz not null,
  period_end timestamptz not null,
  auto_renew boolean not null default true,
  payment_status_code text,
  amount numeric not null default 0,
  currency_code text,
  attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscriptions_period_check check (period_end > period_start),
  constraint subscriptions_amount_check check (amount >= 0),
  constraint subscriptions_currency_required_check check (amount = 0 or currency_code is not null),
  constraint subscriptions_attributes_object_check check (jsonb_typeof(attributes) = 'object')
);

create index if not exists subscriptions_user_status_idx on hfcc.subscriptions (user_id, status_code, period_end desc);
create index if not exists subscriptions_due_expiry_idx on hfcc.subscriptions (status_code, period_end) where status_code = 'hfcc.subscriptions.status_code.active';
create index if not exists subscriptions_payment_method_idx on hfcc.subscriptions (payment_method_id)
  where payment_method_id is not null;
create unique index if not exists subscriptions_initial_order_unique_idx
  on hfcc.subscriptions (initial_order_id)
  where initial_order_id is not null;

comment on table hfcc.subscriptions is
  'Long-lived user subscription contracts created from subscription commerce orders. Orders and order items keep product snapshots and renewal billing cycles.';

create table if not exists hfcc.ledger_wallet_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references hfcc.users(id) on delete cascade,
  source_type text not null,
  source_id uuid,
  grant_key text not null,
  currency_code text not null references hfcc.ledger_currencies(code),
  amount numeric not null,
  recharge_interval_code text not null default 'hfcc.ledger_wallet_grants.recharge_interval_code.once',
  expire_on_next_charge boolean not null default false,
  source_account_id uuid references hfcc.ledger_accounts(id) on delete set null,
  last_charged_at timestamptz,
  next_charge_at timestamptz,
  last_charge_transaction_id uuid references hfcc.ledger_transactions(id) on delete set null,
  status_code text not null default 'hfcc.ledger_wallet_grants.status_code.active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ledger_wallet_grants_amount_check check (amount > 0),
  constraint ledger_wallet_grants_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint ledger_wallet_grants_unique_key unique nulls not distinct (user_id, source_type, source_id, grant_key)
);

create index if not exists ledger_wallet_grants_source_idx
  on hfcc.ledger_wallet_grants (source_type, source_id);
create index if not exists ledger_wallet_grants_user_idx
  on hfcc.ledger_wallet_grants (user_id, currency_code, status_code);
create index if not exists ledger_wallet_grants_due_idx
  on hfcc.ledger_wallet_grants (next_charge_at)
  where status_code = 'hfcc.ledger_wallet_grants.status_code.active' and next_charge_at is not null;

comment on table hfcc.ledger_wallet_grants is
  'Reusable ledger wallet grant state for subscriptions, commerce products, promotions, manual grants, and app-specific sources.';

create or replace function hfcc.prevent_immutable_subscription_update()
returns trigger
language plpgsql
set search_path = hfcc
as $$
begin
  if auth.role() <> 'service_role'
     and old.status_code in ('hfcc.subscriptions.status_code.expired', 'hfcc.subscriptions.status_code.cancelled')
     and old.payment_status_code = 'hfcc.subscriptions.payment_status_code.paid' then
    raise exception 'Past paid subscription rows are immutable'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create or replace trigger prevent_immutable_subscription_update
before update on hfcc.subscriptions
for each row execute function hfcc.prevent_immutable_subscription_update();

create or replace function hfcc.subscription_interval(p_interval_code text)
returns interval
language plpgsql
stable
set search_path = hfcc
as $$
begin
  case
    when p_interval_code like '%.day' then
      return interval '1 day';
    when p_interval_code like '%.week' then
      return interval '1 week';
    when p_interval_code like '%.month' then
      return interval '1 month';
    when p_interval_code like '%.year' then
      return interval '1 year';
    when p_interval_code like '%.once' then
      return null;
    else
      raise exception 'Unsupported interval code: %', p_interval_code
        using errcode = '23514';
  end case;
end;
$$;

create or replace function hfcc.schedule_subscription_lifecycle_jobs(
  p_subscription_id uuid,
  p_create_renewal_order boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_renewal_order_id uuid;
  v_next_period interval;
  v_jobs_created integer := 0;
  v_rows integer := 0;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  insert into hfcc.jobs (job_code, payload, status_code, run_after)
  select
    'hfcc.jobs.job_code.subscription.maintenance_daily',
    jsonb_build_object(
      'handle_job_subscription_maintenance_daily',
      jsonb_build_object('subscription_id', v_subscription.id)
    ),
    'hfcc.jobs.status_code.pending',
    greatest(now() + interval '1 day', v_subscription.period_start)
  where not exists (
    select 1
    from hfcc.jobs j
    where j.job_code = 'hfcc.jobs.job_code.subscription.maintenance_daily'
      and j.status_code = 'hfcc.jobs.status_code.pending'
      and j.payload @> jsonb_build_object(
        'handle_job_subscription_maintenance_daily',
        jsonb_build_object('subscription_id', v_subscription.id)
      )
  );
  get diagnostics v_rows = row_count;
  v_jobs_created := v_jobs_created + v_rows;

  insert into hfcc.jobs (job_code, payload, status_code, run_after)
  select
    'hfcc.jobs.job_code.subscription.expire',
    jsonb_build_object(
      'handle_job_subscription_expire',
      jsonb_build_object('subscription_id', v_subscription.id)
    ),
    'hfcc.jobs.status_code.pending',
    v_subscription.period_end
  where not exists (
    select 1
    from hfcc.jobs j
    where j.job_code = 'hfcc.jobs.job_code.subscription.expire'
      and j.status_code in ('hfcc.jobs.status_code.pending', 'hfcc.jobs.status_code.processing')
      and j.payload @> jsonb_build_object(
        'handle_job_subscription_expire',
        jsonb_build_object('subscription_id', v_subscription.id)
      )
  );
  get diagnostics v_rows = row_count;
  v_jobs_created := v_jobs_created + v_rows;

  v_next_period := hfcc.subscription_interval(v_subscription.billing_interval_code);

  if p_create_renewal_order and v_subscription.auto_renew and v_next_period is not null then
    v_renewal_order_id := hfcc.create_subscription_renewal_order(v_subscription.id, now());

    insert into hfcc.jobs (job_code, payload, status_code, run_after)
    select
      'hfcc.jobs.job_code.subscription.activate',
      jsonb_build_object(
        'handle_job_subscription_activate',
        jsonb_build_object(
          'subscription_id', v_subscription.id,
          'renewal_order_id', v_renewal_order_id
        )
      ),
      'hfcc.jobs.status_code.pending',
      v_subscription.period_end
    where not exists (
      select 1
      from hfcc.jobs j
      where j.job_code = 'hfcc.jobs.job_code.subscription.activate'
        and j.status_code in ('hfcc.jobs.status_code.pending', 'hfcc.jobs.status_code.processing')
        and j.payload @> jsonb_build_object(
          'handle_job_subscription_activate',
          jsonb_build_object(
            'subscription_id', v_subscription.id,
            'renewal_order_id', v_renewal_order_id
          )
        )
    );
    get diagnostics v_rows = row_count;
    v_jobs_created := v_jobs_created + v_rows;

    insert into hfcc.jobs (job_code, payload, status_code, run_after)
    select
      'hfcc.jobs.job_code.subscription.renewal_notice',
      jsonb_build_object(
        'handle_job_subscription_renewal_notice',
        jsonb_build_object(
          'subscription_id', v_subscription.id,
          'renewal_order_id', v_renewal_order_id
        )
      ),
      'hfcc.jobs.status_code.pending',
      greatest(now(), v_subscription.period_end - interval '7 days')
    where not exists (
      select 1
      from hfcc.jobs j
      where j.job_code = 'hfcc.jobs.job_code.subscription.renewal_notice'
        and j.status_code in ('hfcc.jobs.status_code.pending', 'hfcc.jobs.status_code.processing')
        and j.payload @> jsonb_build_object(
          'handle_job_subscription_renewal_notice',
          jsonb_build_object(
            'subscription_id', v_subscription.id,
            'renewal_order_id', v_renewal_order_id
          )
        )
    );
    get diagnostics v_rows = row_count;
    v_jobs_created := v_jobs_created + v_rows;
  end if;

  return jsonb_build_object(
    'subscription_id', p_subscription_id,
    'renewal_order_id', v_renewal_order_id,
    'jobs_created', v_jobs_created
  );
end;
$$;

create or replace function hfcc.activate_scheduled_subscription(
  p_subscription_id uuid,
  p_activated_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_order record;
  v_renewal_order_id uuid;
  v_payment_intent_id uuid;
  v_provider_code text;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  select o.id
  into v_renewal_order_id
  from hfcc.commerce_orders o
  where o.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_renewal'
    and o.status_code in (
      'hfcc.commerce_orders.status_code.pending',
      'hfcc.commerce_orders.status_code.confirmed',
      'hfcc.commerce_orders.status_code.completed'
    )
    and exists (
      select 1
      from hfcc.commerce_order_items i
      where i.order_id = o.id
        and i.subscription_id = p_subscription_id
    )
  order by o.created_at desc
  limit 1;

  if v_renewal_order_id is null then
    v_renewal_order_id := hfcc.create_subscription_renewal_order(p_subscription_id, p_activated_at);
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = v_renewal_order_id
  for update;

  if v_order.total_amount = 0 then
    update hfcc.commerce_orders
    set payment_status_code = 'hfcc.commerce_orders.payment_status_code.paid',
        status_code = 'hfcc.commerce_orders.status_code.confirmed',
        updated_at = now()
    where id = v_order.id;

    perform hfcc.process_commerce_order(v_order.id, p_activated_at);
  else
    select coalesce(
      replace(pm.provider_code, 'commerce_payment_methods.provider_code.', 'commerce_payment_intents.provider_code.'),
      'hfcc.commerce_payment_intents.provider_code.manual'
    )
    into v_provider_code
    from hfcc.commerce_payment_methods pm
    where pm.id = v_subscription.payment_method_id;

    insert into hfcc.commerce_payment_intents (
      order_id,
      user_id,
      provider_code,
      status_code,
      amount,
      currency_code,
      payment_method_id,
      request_payload,
      metadata
    )
    select
      v_order.id,
      v_subscription.user_id,
      coalesce(v_provider_code, 'hfcc.commerce_payment_intents.provider_code.manual'),
      'hfcc.commerce_payment_intents.status_code.pending',
      v_order.total_amount,
      v_order.currency_code,
      v_subscription.payment_method_id,
      jsonb_build_object(
        'subscription_id', v_subscription.id,
        'renewal_order_id', v_order.id,
        'requested_at', p_activated_at
      ),
      jsonb_build_object('source_type', 'subscription_renewal')
    where not exists (
      select 1
      from hfcc.commerce_payment_intents pi
      where pi.order_id = v_order.id
        and pi.status_code in (
          'hfcc.commerce_payment_intents.status_code.pending',
          'hfcc.commerce_payment_intents.status_code.requires_action',
          'hfcc.commerce_payment_intents.status_code.processing',
          'hfcc.commerce_payment_intents.status_code.succeeded'
        )
    )
    returning id into v_payment_intent_id;

    update hfcc.subscriptions
    set status_code = 'hfcc.subscriptions.status_code.paused',
        payment_status_code = 'hfcc.subscriptions.payment_status_code.pending',
        updated_at = now()
    where id = v_subscription.id;
  end if;

  return jsonb_build_object(
    'subscription_id', p_subscription_id,
    'renewal_order_id', v_renewal_order_id,
    'payment_intent_id', v_payment_intent_id
  );
end;
$$;

create or replace function hfcc.enqueue_subscription_renewal_notice(
  p_subscription_id uuid,
  p_requested_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_renewal_order_id uuid;
  v_outbox_event_id uuid;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  select o.id
  into v_renewal_order_id
  from hfcc.commerce_orders o
  where o.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_renewal'
    and o.parent_order_id is not distinct from v_subscription.latest_order_id
    and o.status_code not in (
      'hfcc.commerce_orders.status_code.cancelled',
      'hfcc.commerce_orders.status_code.failed',
      'hfcc.commerce_orders.status_code.refunded'
    )
    and exists (
      select 1
      from hfcc.commerce_order_items i
      where i.order_id = o.id
        and i.subscription_id = p_subscription_id
    )
  order by o.created_at desc
  limit 1;

  v_outbox_event_id := hfcc.enqueue_outbox_event(
    'hfcc.events_outbox.event_code.subscription.renewal_notice_requested',
    'hfcc.events_outbox.source_type.subscription',
    p_subscription_id,
    jsonb_build_object(
      'subscription_id', p_subscription_id,
      'renewal_order_id', v_renewal_order_id,
      'user_id', v_subscription.user_id,
      'period_start', v_subscription.period_start,
      'period_end', v_subscription.period_end,
      'requested_at', p_requested_at
    ),
    '{}'::jsonb,
    p_requested_at
  );

  return v_outbox_event_id;
end;
$$;

create or replace function hfcc.apply_subscription_entitlements(
  p_subscription_id uuid,
  p_source_account_id uuid default null,
  p_applied_at timestamptz default now(),
  p_charge_initial boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  if v_subscription.status_code <> 'hfcc.subscriptions.status_code.active' then
    raise exception 'Subscription % is not active', p_subscription_id
      using errcode = '23514';
  end if;

  perform hfcc.schedule_subscription_lifecycle_jobs(p_subscription_id, true);

  return jsonb_build_object(
    'subscription_id', p_subscription_id,
    'scheduled', true
  );
end;
$$;

create or replace function hfcc.after_subscription_activation()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if tg_op = 'UPDATE'
     and new.status_code = 'hfcc.subscriptions.status_code.active'
     and (new.amount = 0 or new.payment_status_code = 'hfcc.subscriptions.payment_status_code.paid')
     and (
       old.status_code is distinct from new.status_code
       or old.payment_status_code is distinct from new.payment_status_code
     ) then
    perform hfcc.apply_subscription_entitlements(
      new.id,
      null,
      new.period_start,
      false
    );
  end if;

  return new;
end;
$$;

create or replace trigger after_subscription_activation
after insert or update of status_code, payment_status_code on hfcc.subscriptions
for each row execute function hfcc.after_subscription_activation();

create or replace function hfcc.process_subscription_maintenance(
  p_subscription_id uuid,
  p_processed_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_grant hfcc.ledger_wallet_grants%rowtype;
  v_interval interval;
  v_user_account_id uuid;
  v_source_account_id uuid;
  v_used_amount numeric;
  v_unused_amount numeric;
  v_expired_total numeric := 0;
  v_recharged_total numeric := 0;
  v_transaction_id uuid;
  v_is_expired boolean := false;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  v_is_expired := v_subscription.period_end <= p_processed_at
                  and v_subscription.status_code = 'hfcc.subscriptions.status_code.active';

  for v_grant in
    select *
    from hfcc.ledger_wallet_grants spe
    where spe.source_type = 'hfcc.ledger_wallet_grants.source_type.subscription'
      and spe.source_id = p_subscription_id
      and spe.status_code = 'hfcc.ledger_wallet_grants.status_code.active'
      and (
        v_is_expired
        or (spe.next_charge_at is not null and spe.next_charge_at <= p_processed_at)
      )
    for update
  loop
    select la.id
    into v_user_account_id
    from hfcc.ledger_accounts la
    where la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = v_grant.user_id
      and la.currency_code = v_grant.currency_code
      and la.account_type_code = 'hfcc.ledger_accounts.account_type_code.user_wallet'
    limit 1;

    v_source_account_id := v_grant.source_account_id;

    if v_source_account_id is null then
      select la.id
      into v_source_account_id
      from hfcc.ledger_accounts la
      where la.owner_type = 'hfcc.ledger_accounts.owner_type.system'
        and la.currency_code = v_grant.currency_code
        and la.account_type_code in (
          'hfcc.ledger_accounts.account_type_code.system',
          'hfcc.ledger_accounts.account_type_code.liability'
        )
      order by case la.account_type_code
        when 'hfcc.ledger_accounts.account_type_code.system' then 1
        when 'hfcc.ledger_accounts.account_type_code.liability' then 2
        else 3
      end
      limit 1;
    end if;

    if v_user_account_id is null or v_source_account_id is null then
      raise exception 'Missing ledger accounts for wallet grant %', v_grant.id
        using errcode = '23503';
    end if;

    if v_grant.expire_on_next_charge and v_grant.last_charged_at is not null then
      select least(
        v_grant.amount,
        coalesce(sum(abs(le.amount)) filter (where le.amount < 0), 0)
      )
      into v_used_amount
      from hfcc.ledger_entries le
      join hfcc.ledger_transactions lt on lt.id = le.transaction_id
      where le.account_id = v_user_account_id
        and lt.created_at > v_grant.last_charged_at
        and lt.created_at <= p_processed_at
        and lt.transaction_code <> 'hfcc.ledger_transactions.transaction_code.wallet_grant_expiry';

      v_unused_amount := greatest(v_grant.amount - coalesce(v_used_amount, 0), 0);

      if v_unused_amount > 0 then
        v_transaction_id := hfcc.create_ledger_transaction(
          'hfcc.ledger_transactions.transaction_code.wallet_grant_expiry',
          p_subscription_id,
          jsonb_build_array(
            jsonb_build_object('account_id', v_user_account_id, 'amount', -v_unused_amount),
            jsonb_build_object('account_id', v_source_account_id, 'amount', v_unused_amount)
          ),
          'Expire unused wallet grant',
          jsonb_build_object(
            'source_type', 'hfcc.ledger_transactions.source_type.subscription',
            'subscription_id', p_subscription_id,
            'ledger_wallet_grant_id', v_grant.id,
            'currency_code', v_grant.currency_code,
            'expired_amount', v_unused_amount,
            'processed_at', p_processed_at
          )
        );

        v_expired_total := v_expired_total + v_unused_amount;
      end if;
    end if;

    if v_is_expired then
      update hfcc.ledger_wallet_grants
      set status_code = 'hfcc.ledger_wallet_grants.status_code.expired',
          updated_at = now()
      where id = v_grant.id;
    else
      v_transaction_id := hfcc.create_ledger_transaction(
        'hfcc.ledger_transactions.transaction_code.wallet_grant',
        p_subscription_id,
        jsonb_build_array(
          jsonb_build_object('account_id', v_source_account_id, 'amount', -v_grant.amount),
          jsonb_build_object('account_id', v_user_account_id, 'amount', v_grant.amount)
        ),
        'Wallet grant recharge',
        jsonb_build_object(
          'source_type', 'hfcc.ledger_transactions.source_type.subscription',
          'subscription_id', p_subscription_id,
          'ledger_wallet_grant_id', v_grant.id,
          'currency_code', v_grant.currency_code,
          'amount', v_grant.amount,
          'processed_at', p_processed_at
        )
      );

      v_interval := hfcc.subscription_interval(v_grant.recharge_interval_code);

      update hfcc.ledger_wallet_grants
      set last_charged_at = p_processed_at,
          next_charge_at = case when v_interval is null then null else p_processed_at + v_interval end,
          last_charge_transaction_id = v_transaction_id,
          updated_at = now()
      where id = v_grant.id;

      v_recharged_total := v_recharged_total + v_grant.amount;
    end if;
  end loop;

  if v_is_expired then
    update hfcc.subscriptions
    set status_code = 'hfcc.subscriptions.status_code.expired',
        updated_at = now()
    where id = p_subscription_id;

    update hfcc.jobs j
    set status_code = 'hfcc.jobs.status_code.cancelled',
        processed_at = p_processed_at,
        updated_at = now()
    where j.status_code in ('hfcc.jobs.status_code.pending', 'hfcc.jobs.status_code.processing')
      and j.job_code in (
        'hfcc.jobs.job_code.subscription.maintenance_daily',
        'hfcc.jobs.job_code.subscription.expire',
        'hfcc.jobs.job_code.subscription.activate',
        'hfcc.jobs.job_code.subscription.renewal_notice'
      )
      and (
        j.payload @> jsonb_build_object(
          'handle_job_subscription_maintenance_daily',
          jsonb_build_object('subscription_id', p_subscription_id)
        )
        or j.payload @> jsonb_build_object(
          'handle_job_subscription_expire',
          jsonb_build_object('subscription_id', p_subscription_id)
        )
        or j.payload @> jsonb_build_object(
          'handle_job_subscription_activate',
          jsonb_build_object('subscription_id', p_subscription_id)
        )
        or j.payload @> jsonb_build_object(
          'handle_job_subscription_renewal_notice',
          jsonb_build_object('subscription_id', p_subscription_id)
        )
      );

    update hfcc.commerce_orders o
    set status_code = 'hfcc.commerce_orders.status_code.failed',
        payment_status_code = case
          when o.payment_status_code = 'hfcc.commerce_orders.payment_status_code.paid'
            then o.payment_status_code
          else 'hfcc.commerce_orders.payment_status_code.failed'
        end,
        updated_at = now()
    where o.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_renewal'
      and o.status_code in (
        'hfcc.commerce_orders.status_code.draft',
        'hfcc.commerce_orders.status_code.pending'
      )
      and exists (
        select 1
        from hfcc.commerce_order_items i
        where i.order_id = o.id
          and i.subscription_id = p_subscription_id
      );
  else
    perform hfcc.schedule_subscription_lifecycle_jobs(p_subscription_id, true);
  end if;

  return jsonb_build_object(
    'subscription_id', p_subscription_id,
    'expired', v_is_expired,
    'expired_total', v_expired_total,
    'recharged_total', v_recharged_total
  );
end;
$$;

create table if not exists hfcc.promotions (
  id uuid primary key default extensions.gen_random_uuid(),
  code text unique,
  promotion_type_code text not null,
  campaign_code text,
  campaign_name text,
  created_by_user_id uuid references hfcc.users(id) on delete set null,
  max_uses integer,
  used_count integer not null default 0,
  per_user_limit integer,
  starts_at timestamptz,
  expires_at timestamptz,
  rules jsonb not null default '{}'::jsonb,
  attributes jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint promotions_used_count_check check (used_count >= 0),
  constraint promotions_used_count_max_check check (max_uses is null or used_count <= max_uses),
  constraint promotions_max_uses_check check (max_uses is null or max_uses > 0),
  constraint promotions_per_user_limit_check check (per_user_limit is null or per_user_limit > 0),
  constraint promotions_expiry_check check (expires_at is null or starts_at is null or expires_at > starts_at),
  constraint promotions_rules_object_check check (jsonb_typeof(rules) = 'object'),
  constraint promotions_attributes_object_check check (jsonb_typeof(attributes) = 'object')
);

create index if not exists promotions_active_idx on hfcc.promotions (is_active, starts_at, expires_at);
create index if not exists promotions_created_by_idx on hfcc.promotions (created_by_user_id);

comment on table hfcc.promotions is
  'Reusable coupon, referral, and promotion definitions.';

create table if not exists hfcc.promotion_usages (
  id uuid primary key default extensions.gen_random_uuid(),
  promotion_id uuid not null references hfcc.promotions(id) on delete cascade,
  user_id uuid not null references hfcc.users(id) on delete cascade,
  context_type text,
  context_id uuid,
  source_type text,
  source_id uuid,
  created_at timestamptz not null default now(),
  constraint promotion_usages_unique_context unique nulls not distinct (
    promotion_id,
    user_id,
    context_type,
    context_id
  )
);

create index if not exists promotion_usages_user_idx on hfcc.promotion_usages (user_id, created_at desc);
create index if not exists promotion_usages_promotion_idx on hfcc.promotion_usages (promotion_id, created_at desc);

comment on table hfcc.promotion_usages is
  'Idempotent promotion use records with counters and limit enforcement.';

create or replace function hfcc.validate_promotion_for_user(
  p_user_id uuid,
  p_code text,
  p_context_type text default null,
  p_context_id uuid default null,
  p_promotion_id uuid default null
)
returns table (
  is_valid boolean,
  reason_code text,
  message text,
  promotion_id uuid
)
language plpgsql
stable
set search_path = hfcc
as $$
declare
  v_promotion hfcc.promotions%rowtype;
  v_user_usage_count integer;
  v_context_usage_exists boolean;
begin
  if p_user_id is null then
    return query select false, 'user_required', 'User id is required', null::uuid;
    return;
  end if;

  if p_promotion_id is null and nullif(btrim(coalesce(p_code, '')), '') is null then
    return query select false, 'promotion_required', 'Promotion code or id is required', null::uuid;
    return;
  end if;

  if not exists (select 1 from hfcc.users p where p.id = p_user_id) then
    return query select false, 'user_not_found', 'User does not exist', null::uuid;
    return;
  end if;

  select p.*
  into v_promotion
  from hfcc.promotions p
  where (p_promotion_id is not null and p.id = p_promotion_id)
     or (p_promotion_id is null and lower(p.code) = lower(btrim(p_code)))
  limit 1;

  if not found then
    return query select false, 'promotion_not_found', 'Promotion was not found', null::uuid;
    return;
  end if;

  if not v_promotion.is_active then
    return query select false, 'promotion_inactive', 'Promotion is inactive', v_promotion.id;
    return;
  end if;

  if v_promotion.starts_at is not null and v_promotion.starts_at > now() then
    return query select false, 'promotion_not_started', 'Promotion has not started', v_promotion.id;
    return;
  end if;

  if v_promotion.expires_at is not null and v_promotion.expires_at <= now() then
    return query select false, 'promotion_expired', 'Promotion has expired', v_promotion.id;
    return;
  end if;

  if v_promotion.max_uses is not null and v_promotion.used_count >= v_promotion.max_uses then
    return query select false, 'max_uses_reached', 'Promotion has reached its maximum usage count', v_promotion.id;
    return;
  end if;

  if p_context_type is not null or p_context_id is not null then
    select exists (
      select 1
      from hfcc.promotion_usages pu
      where pu.promotion_id = v_promotion.id
        and pu.user_id = p_user_id
        and pu.context_type is not distinct from p_context_type
        and pu.context_id is not distinct from p_context_id
    )
    into v_context_usage_exists;

    if v_context_usage_exists then
      return query select false, 'context_already_used', 'Promotion was already used for this context', v_promotion.id;
      return;
    end if;
  end if;

  if v_promotion.per_user_limit is not null then
    select count(*)
    into v_user_usage_count
    from hfcc.promotion_usages pu
    where pu.promotion_id = v_promotion.id
      and pu.user_id = p_user_id;

    if v_user_usage_count >= v_promotion.per_user_limit then
      return query select false, 'per_user_limit_reached', 'Promotion per-user limit has been reached', v_promotion.id;
      return;
    end if;
  end if;

  return query select true, 'valid', 'Promotion is valid', v_promotion.id;
end;
$$;

create or replace function hfcc.validate_promotion_usage()
returns trigger
language plpgsql
set search_path = hfcc
as $$
declare
  v_validation record;
begin
  perform 1
  from hfcc.promotions p
  where p.id = new.promotion_id
  for update;

  select *
  into v_validation
  from hfcc.validate_promotion_for_user(
    new.user_id,
    null,
    new.context_type,
    new.context_id,
    new.promotion_id
  );

  if not coalesce(v_validation.is_valid, false) then
    raise exception 'Promotion usage is not valid: %', coalesce(v_validation.reason_code, 'unknown')
      using errcode = '23514',
            detail = coalesce(v_validation.message, 'Promotion validation failed');
  end if;

  return new;
end;
$$;

create or replace function hfcc.after_promotion_usage_insert()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  update hfcc.promotions
  set used_count = used_count + 1,
      updated_at = now()
  where id = new.promotion_id;

  return new;
end;
$$;

create or replace function hfcc.apply_promotion(
  p_user_id uuid,
  p_code text,
  p_context_type text default null,
  p_context_id uuid default null,
  p_source_type text default null,
  p_source_id uuid default null,
  p_source_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_validation record;
  v_promotion hfcc.promotions%rowtype;
  v_usage_id uuid;
  v_grant_record record;
  v_grant jsonb;
  v_wallet_grants jsonb;
  v_wallet_grant_id uuid;
  v_wallet_grant_ids jsonb := '[]'::jsonb;
  v_grant_key text;
  v_currency_code text;
  v_amount numeric;
  v_recharge_interval_code text;
  v_recharge_interval interval;
  v_expire_on_next_charge boolean;
  v_user_account_id uuid;
  v_source_account_id uuid;
  v_transaction_id uuid;
  v_transactions jsonb := '[]'::jsonb;
  v_last_charged_at timestamptz;
begin
  select *
  into v_validation
  from hfcc.validate_promotion_for_user(p_user_id, p_code, p_context_type, p_context_id);

  if not coalesce(v_validation.is_valid, false) then
    return jsonb_build_object(
      'is_valid', false,
      'reason_code', v_validation.reason_code,
      'message', v_validation.message,
      'promotion_id', v_validation.promotion_id
    );
  end if;

  select *
  into v_promotion
  from hfcc.promotions
  where id = v_validation.promotion_id
  for update;

  insert into hfcc.promotion_usages (
    promotion_id,
    user_id,
    context_type,
    context_id,
    source_type,
    source_id
  )
  values (
    v_promotion.id,
    p_user_id,
    p_context_type,
    p_context_id,
    p_source_type,
    p_source_id
  )
  returning id into v_usage_id;

  if v_promotion.rules ? 'ledger_wallet_grants' then
    if jsonb_typeof(v_promotion.rules -> 'ledger_wallet_grants') <> 'array' then
      raise exception 'promotions.rules.ledger_wallet_grants must be an array'
        using errcode = '23514';
    end if;

    v_wallet_grants := v_promotion.rules -> 'ledger_wallet_grants';
  else
    v_wallet_grants := '[]'::jsonb;
  end if;

  if jsonb_array_length(v_wallet_grants) > 0 then
    perform hfcc.ensure_user_ledger_accounts(p_user_id);
  end if;

  for v_grant_record in
    select value, ordinality
    from jsonb_array_elements(v_wallet_grants) with ordinality
  loop
    v_grant := v_grant_record.value;

    if jsonb_typeof(v_grant) <> 'object' then
      raise exception 'Each promotion wallet grant must be an object'
        using errcode = '23514';
    end if;

    v_currency_code := v_grant ->> 'currency_code';
    v_grant_key := coalesce(nullif(v_grant ->> 'key', ''), v_currency_code || ':' || v_grant_record.ordinality::text);
    v_amount := nullif(v_grant ->> 'amount', '')::numeric;
    v_recharge_interval_code := 'hfcc.ledger_wallet_grants.recharge_interval_code.' || coalesce(v_grant ->> 'recharge_interval', 'once');
    v_recharge_interval := hfcc.subscription_interval(v_recharge_interval_code);
    v_expire_on_next_charge := coalesce((v_grant ->> 'expire_on_next_charge')::boolean, false);

    if v_currency_code is null or v_amount is null or v_amount <= 0 then
      raise exception 'Each promotion wallet grant requires currency_code and positive amount'
        using errcode = '23514';
    end if;

    select la.id
    into v_user_account_id
    from hfcc.ledger_accounts la
    where la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = p_user_id
      and la.currency_code = v_currency_code
      and la.account_type_code = 'hfcc.ledger_accounts.account_type_code.user_wallet'
    limit 1;

    if v_user_account_id is null then
      raise exception 'User wallet account for % does not exist', v_currency_code
        using errcode = '23503';
    end if;

    v_source_account_id := coalesce(p_source_account_id, nullif(v_grant ->> 'source_account_id', '')::uuid);

    if v_source_account_id is null then
      select la.id
      into v_source_account_id
      from hfcc.ledger_accounts la
      where la.owner_type = 'hfcc.ledger_accounts.owner_type.system'
        and la.currency_code = v_currency_code
        and la.account_type_code in (
          'hfcc.ledger_accounts.account_type_code.promotion_pool',
          'hfcc.ledger_accounts.account_type_code.system',
          'hfcc.ledger_accounts.account_type_code.liability'
        )
      order by case la.account_type_code
        when 'hfcc.ledger_accounts.account_type_code.promotion_pool' then 1
        when 'hfcc.ledger_accounts.account_type_code.system' then 2
        when 'hfcc.ledger_accounts.account_type_code.liability' then 3
        else 4
      end
      limit 1;
    end if;

    if v_source_account_id is null then
      raise exception 'No source system account found for % promotion wallet grant', v_currency_code
        using errcode = '23503';
    end if;

    insert into hfcc.ledger_wallet_grants (
      user_id,
      source_type,
      source_id,
      grant_key,
      currency_code,
      amount,
      recharge_interval_code,
      expire_on_next_charge,
      source_account_id,
      next_charge_at,
      metadata
    )
    values (
      p_user_id,
      'hfcc.ledger_wallet_grants.source_type.promotion_usage',
      v_usage_id,
      v_grant_key,
      v_currency_code,
      v_amount,
      v_recharge_interval_code,
      v_expire_on_next_charge,
      v_source_account_id,
      case when v_recharge_interval is null then null else now() + v_recharge_interval end,
      jsonb_build_object(
        'promotion_id', v_promotion.id,
        'promotion_usage_id', v_usage_id,
        'promotion_grant', v_grant
      )
    )
    on conflict (user_id, source_type, source_id, grant_key) do update
    set amount = excluded.amount,
        recharge_interval_code = excluded.recharge_interval_code,
        expire_on_next_charge = excluded.expire_on_next_charge,
        source_account_id = excluded.source_account_id,
        metadata = excluded.metadata,
        status_code = 'hfcc.ledger_wallet_grants.status_code.active',
        updated_at = now()
    returning id, last_charged_at into v_wallet_grant_id, v_last_charged_at;

    v_wallet_grant_ids := v_wallet_grant_ids || jsonb_build_array(v_wallet_grant_id);

    if v_last_charged_at is not null then
      continue;
    end if;

    v_transaction_id := hfcc.create_ledger_transaction(
      'hfcc.ledger_transactions.transaction_code.wallet_grant',
      v_usage_id,
      jsonb_build_array(
        jsonb_build_object('account_id', v_source_account_id, 'amount', -v_amount),
        jsonb_build_object('account_id', v_user_account_id, 'amount', v_amount)
      ),
      'Promotion wallet grant',
      jsonb_build_object(
        'promotion_id', v_promotion.id,
        'promotion_usage_id', v_usage_id,
        'source_type', 'hfcc.ledger_transactions.source_type.promotion_usage',
        'ledger_wallet_grant_id', v_wallet_grant_id,
        'grant_key', v_grant_key,
        'user_id', p_user_id,
        'currency_code', v_currency_code,
        'amount', v_amount,
        'recharge_interval_code', v_recharge_interval_code,
        'expire_on_next_charge', v_expire_on_next_charge
      )
    );

    update hfcc.ledger_wallet_grants
    set last_charged_at = now(),
        next_charge_at = case when v_recharge_interval is null then null else now() + v_recharge_interval end,
        last_charge_transaction_id = v_transaction_id,
        updated_at = now()
    where id = v_wallet_grant_id;

    v_transactions := v_transactions || jsonb_build_array(v_transaction_id);
  end loop;

  return jsonb_build_object(
    'is_valid', true,
    'promotion_id', v_promotion.id,
    'promotion_usage_id', v_usage_id,
    'ledger_wallet_grant_ids', v_wallet_grant_ids,
    'ledger_transaction_ids', v_transactions
  );
end;
$$;

create or replace trigger validate_promotion_usage
before insert on hfcc.promotion_usages
for each row execute function hfcc.validate_promotion_usage();

create or replace trigger after_promotion_usage_insert
after insert on hfcc.promotion_usages
for each row execute function hfcc.after_promotion_usage_insert();

-- ---------------------------------------------------------------------------
-- Commerce core
-- ---------------------------------------------------------------------------

create table if not exists hfcc.commerce_products (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  description text,
  product_type_code text not null,
  status_code text not null default 'hfcc.commerce_products.status_code.draft',
  price_amount numeric not null default 0,
  price_currency_code text,
  taxable boolean not null default false,
  attributes jsonb not null default '{}'::jsonb,
  rules jsonb not null default '{}'::jsonb,
  entitlements jsonb not null default '{}'::jsonb,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_products_name_not_blank_check check (length(btrim(name)) > 0),
  constraint commerce_products_price_amount_check check (price_amount >= 0),
  constraint commerce_products_price_currency_check check (price_amount = 0 or price_currency_code is not null),
  constraint commerce_products_attributes_object_check check (jsonb_typeof(attributes) = 'object'),
  constraint commerce_products_rules_object_check check (jsonb_typeof(rules) = 'object'),
  constraint commerce_products_entitlements_object_check check (jsonb_typeof(entitlements) = 'object'),
  constraint commerce_products_payload_object_check check (jsonb_typeof(payload) = 'object'),
  constraint commerce_products_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commerce_products_active_idx
  on hfcc.commerce_products (is_active, status_code, product_type_code);
create index if not exists commerce_products_price_currency_idx
  on hfcc.commerce_products (price_currency_code);

comment on table hfcc.commerce_products is
  'Reusable commerce product definitions without inventory, fulfillment, variant, or app-specific operational concerns.';

create table if not exists hfcc.commerce_orders (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references hfcc.users(id) on delete restrict,
  order_type_code text not null default 'hfcc.commerce_orders.order_type_code.one_time',
  parent_order_id uuid references hfcc.commerce_orders(id) on delete set null,
  status_code text not null default 'hfcc.commerce_orders.status_code.draft',
  payment_status_code text not null default 'hfcc.commerce_orders.payment_status_code.unpaid',
  billing_interval_code text,
  subtotal_amount numeric not null default 0,
  discount_amount numeric not null default 0,
  tax_amount numeric not null default 0,
  shipping_amount numeric not null default 0,
  total_amount numeric not null default 0,
  currency_code text not null,
  billing_info jsonb not null default '{}'::jsonb,
  shipping_info jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_orders_amounts_check check (
    subtotal_amount >= 0
    and discount_amount >= 0
    and tax_amount >= 0
    and shipping_amount >= 0
    and total_amount >= 0
  ),
  constraint commerce_orders_subscription_interval_check check (
    order_type_code not in (
      'hfcc.commerce_orders.order_type_code.subscription_initial',
      'hfcc.commerce_orders.order_type_code.subscription_renewal'
    )
    or billing_interval_code is not null
  ),
  constraint commerce_orders_billing_info_object_check check (jsonb_typeof(billing_info) = 'object'),
  constraint commerce_orders_shipping_info_object_check check (jsonb_typeof(shipping_info) = 'object'),
  constraint commerce_orders_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commerce_orders_user_idx
  on hfcc.commerce_orders (user_id, created_at desc);
create index if not exists commerce_orders_status_idx
  on hfcc.commerce_orders (status_code, payment_status_code, created_at desc);
create index if not exists commerce_orders_parent_idx
  on hfcc.commerce_orders (parent_order_id)
  where parent_order_id is not null;

comment on table hfcc.commerce_orders is
  'Generic commerce order headers with billing, shipping, totals, and payment state.';

create table if not exists hfcc.commerce_order_items (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references hfcc.commerce_orders(id) on delete cascade,
  product_id uuid references hfcc.commerce_products(id) on delete restrict,
  subscription_id uuid references hfcc.subscriptions(id) on delete set null,
  status_code text not null default 'hfcc.commerce_order_items.status_code.pending',
  quantity numeric not null default 1,
  unit_amount numeric not null default 0,
  subtotal_amount numeric not null default 0,
  discount_amount numeric not null default 0,
  tax_amount numeric not null default 0,
  total_amount numeric not null default 0,
  currency_code text not null,
  rules_snapshot jsonb not null default '{}'::jsonb,
  entitlements_snapshot jsonb not null default '{}'::jsonb,
  payload_snapshot jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_order_items_quantity_check check (quantity > 0),
  constraint commerce_order_items_amounts_check check (
    unit_amount >= 0
    and subtotal_amount >= 0
    and discount_amount >= 0
    and tax_amount >= 0
    and total_amount >= 0
  ),
  constraint commerce_order_items_rules_snapshot_object_check check (jsonb_typeof(rules_snapshot) = 'object'),
  constraint commerce_order_items_entitlements_snapshot_object_check check (jsonb_typeof(entitlements_snapshot) = 'object'),
  constraint commerce_order_items_payload_snapshot_object_check check (jsonb_typeof(payload_snapshot) = 'object'),
  constraint commerce_order_items_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commerce_order_items_order_idx
  on hfcc.commerce_order_items (order_id, created_at);
create index if not exists commerce_order_items_product_idx
  on hfcc.commerce_order_items (product_id, created_at desc)
  where product_id is not null;
create index if not exists commerce_order_items_subscription_idx
  on hfcc.commerce_order_items (subscription_id, created_at desc)
  where subscription_id is not null;
create index if not exists commerce_order_items_status_idx
  on hfcc.commerce_order_items (status_code, created_at desc);

comment on table hfcc.commerce_order_items is
  'Commerce order line snapshots. Product rules, entitlements, and payload are copied here at purchase time.';

create table if not exists hfcc.commerce_payment_methods (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references hfcc.users(id) on delete cascade,
  provider_code text not null,
  payment_method_type_code text not null,
  provider_payment_method_id text,
  label text,
  billing_info jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_payment_methods_provider_payment_method_not_blank_check
    check (provider_payment_method_id is null or length(btrim(provider_payment_method_id)) > 0),
  constraint commerce_payment_methods_billing_info_object_check check (jsonb_typeof(billing_info) = 'object'),
  constraint commerce_payment_methods_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists commerce_payment_methods_provider_unique_idx
  on hfcc.commerce_payment_methods (user_id, provider_code, provider_payment_method_id)
  where provider_payment_method_id is not null;
create unique index if not exists commerce_payment_methods_default_unique_idx
  on hfcc.commerce_payment_methods (user_id)
  where is_default;
create index if not exists commerce_payment_methods_user_idx
  on hfcc.commerce_payment_methods (user_id, created_at desc);

comment on table hfcc.commerce_payment_methods is
  'Tokenized or external user payment method references. Sensitive raw payment data must not be stored here.';

create table if not exists hfcc.commerce_payment_intents (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references hfcc.commerce_orders(id) on delete cascade,
  user_id uuid not null references hfcc.users(id) on delete restrict,
  provider_code text not null,
  status_code text not null default 'hfcc.commerce_payment_intents.status_code.pending',
  amount numeric not null,
  currency_code text not null,
  provider_payment_intent_id text,
  payment_method_id uuid references hfcc.commerce_payment_methods(id) on delete set null,
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commerce_payment_intents_amount_check check (amount >= 0),
  constraint commerce_payment_intents_provider_payment_intent_not_blank_check
    check (provider_payment_intent_id is null or length(btrim(provider_payment_intent_id)) > 0),
  constraint commerce_payment_intents_request_payload_object_check check (jsonb_typeof(request_payload) = 'object'),
  constraint commerce_payment_intents_response_payload_object_check check (jsonb_typeof(response_payload) = 'object'),
  constraint commerce_payment_intents_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists commerce_payment_intents_provider_unique_idx
  on hfcc.commerce_payment_intents (provider_code, provider_payment_intent_id)
  where provider_payment_intent_id is not null;
create index if not exists commerce_payment_intents_order_idx
  on hfcc.commerce_payment_intents (order_id, created_at desc);
create index if not exists commerce_payment_intents_user_idx
  on hfcc.commerce_payment_intents (user_id, created_at desc);
create index if not exists commerce_payment_intents_status_idx
  on hfcc.commerce_payment_intents (status_code, created_at desc);

comment on table hfcc.commerce_payment_intents is
  'Provider payment attempts for commerce orders.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'subscriptions_initial_order_id_fkey'
      and conrelid = 'hfcc.subscriptions'::regclass
  ) then
    alter table hfcc.subscriptions
      add constraint subscriptions_initial_order_id_fkey
      foreign key (initial_order_id) references hfcc.commerce_orders(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'subscriptions_payment_method_id_fkey'
      and conrelid = 'hfcc.subscriptions'::regclass
  ) then
    alter table hfcc.subscriptions
      add constraint subscriptions_payment_method_id_fkey
      foreign key (payment_method_id) references hfcc.commerce_payment_methods(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'subscriptions_latest_order_id_fkey'
      and conrelid = 'hfcc.subscriptions'::regclass
  ) then
    alter table hfcc.subscriptions
      add constraint subscriptions_latest_order_id_fkey
      foreign key (latest_order_id) references hfcc.commerce_orders(id) on delete set null;
  end if;
end;
$$;

create or replace function hfcc.create_subscription_from_order(
  p_order_id uuid,
  p_period_start timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
  v_billing_interval_code text;
  v_period interval;
  v_subscription_id uuid;
  v_payment_method_id uuid;
begin
  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Commerce order % does not exist', p_order_id
      using errcode = '23503';
  end if;

  if v_order.order_type_code <> 'hfcc.commerce_orders.order_type_code.subscription_initial' then
    raise exception 'Commerce order % must be subscription_initial to create a subscription', p_order_id
      using errcode = '23514';
  end if;

  if v_order.total_amount > 0
     and v_order.payment_status_code <> 'hfcc.commerce_orders.payment_status_code.paid' then
    raise exception 'Commerce order % must be paid before creating a subscription', v_order.id
      using errcode = '23514';
  end if;

  select s.id
  into v_subscription_id
  from hfcc.subscriptions s
  where s.initial_order_id = v_order.id
  limit 1;

  if v_subscription_id is not null then
    return v_subscription_id;
  end if;

  v_billing_interval_code := v_order.billing_interval_code;

  if v_billing_interval_code is null then
    raise exception 'Commerce order % requires billing_interval_code before creating a subscription', v_order.id
      using errcode = '23514';
  end if;

  v_period := hfcc.subscription_interval(v_billing_interval_code);

  if v_period is null then
    raise exception 'Commerce order % cannot create a renewable subscription with interval once', v_order.id
      using errcode = '23514';
  end if;

  select pi.payment_method_id
  into v_payment_method_id
  from hfcc.commerce_payment_intents pi
  where pi.order_id = v_order.id
    and pi.payment_method_id is not null
    and pi.status_code = 'hfcc.commerce_payment_intents.status_code.succeeded'
  order by pi.created_at desc
  limit 1;

  if v_payment_method_id is null then
    select pm.id
    into v_payment_method_id
    from hfcc.commerce_payment_methods pm
    where pm.user_id = v_order.user_id
      and pm.is_default
    order by pm.created_at desc
    limit 1;
  end if;

  insert into hfcc.subscriptions (
    user_id,
    payment_method_id,
    billing_interval_code,
    initial_order_id,
    latest_order_id,
    status_code,
    period_start,
    period_end,
    auto_renew,
    payment_status_code,
    amount,
    currency_code,
    attributes
  )
  values (
    v_order.user_id,
    v_payment_method_id,
    v_billing_interval_code,
    v_order.id,
    v_order.id,
    'hfcc.subscriptions.status_code.active',
    p_period_start,
    p_period_start + v_period,
    true,
    case
      when v_order.payment_status_code = 'hfcc.commerce_orders.payment_status_code.paid'
        then 'hfcc.subscriptions.payment_status_code.paid'
      else 'hfcc.subscriptions.payment_status_code.pending'
    end,
    v_order.total_amount,
    v_order.currency_code,
    jsonb_build_object(
      'source', 'commerce_order',
      'commerce_order_id', v_order.id
    )
  )
  returning id into v_subscription_id;

  update hfcc.commerce_order_items
  set subscription_id = v_subscription_id,
      updated_at = now()
  where order_id = v_order.id;

  update hfcc.commerce_orders
  set metadata = metadata || jsonb_build_object(
        'subscription',
        coalesce(metadata -> 'subscription', '{}'::jsonb) || jsonb_build_object(
          'subscription_id', v_subscription_id,
          'billing_period_start', p_period_start,
          'billing_period_end', p_period_start + v_period,
          'cycle', 1
        )
      ),
      updated_at = now()
  where id = v_order.id;

  perform hfcc.schedule_subscription_lifecycle_jobs(v_subscription_id, true);

  return v_subscription_id;
end;
$$;

create or replace function hfcc.create_subscription_renewal_order(
  p_subscription_id uuid,
  p_requested_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_period interval;
  v_order_id uuid;
  v_cycle integer;
  v_inserted_items integer;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  if v_subscription.status_code <> 'hfcc.subscriptions.status_code.active' then
    raise exception 'Subscription % must be active before a renewal order can be created', p_subscription_id
      using errcode = '23514';
  end if;

  v_period := hfcc.subscription_interval(v_subscription.billing_interval_code);

  if v_period is null then
    return null;
  end if;

  select o.id
  into v_order_id
  from hfcc.commerce_orders o
  where o.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_renewal'
    and o.parent_order_id is not distinct from v_subscription.latest_order_id
    and o.status_code not in (
      'hfcc.commerce_orders.status_code.cancelled',
      'hfcc.commerce_orders.status_code.failed',
      'hfcc.commerce_orders.status_code.refunded'
    )
    and exists (
      select 1
      from hfcc.commerce_order_items i
      where i.order_id = o.id
        and i.subscription_id = p_subscription_id
    )
  order by o.created_at desc
  limit 1;

  if v_order_id is not null then
    return v_order_id;
  end if;

  select count(*) + 1
  into v_cycle
  from hfcc.commerce_orders o
  where o.order_type_code in (
      'hfcc.commerce_orders.order_type_code.subscription_initial',
      'hfcc.commerce_orders.order_type_code.subscription_renewal'
    )
    and exists (
      select 1
      from hfcc.commerce_order_items i
      where i.order_id = o.id
        and i.subscription_id = p_subscription_id
    );

  insert into hfcc.commerce_orders (
    user_id,
    order_type_code,
    parent_order_id,
    status_code,
    payment_status_code,
    billing_interval_code,
    subtotal_amount,
    discount_amount,
    tax_amount,
    shipping_amount,
    total_amount,
    currency_code,
    billing_info,
    shipping_info,
    metadata
  )
  select
    v_subscription.user_id,
    'hfcc.commerce_orders.order_type_code.subscription_renewal',
    v_subscription.latest_order_id,
    'hfcc.commerce_orders.status_code.pending',
    case
      when v_subscription.amount > 0 then 'hfcc.commerce_orders.payment_status_code.pending'
      else 'hfcc.commerce_orders.payment_status_code.paid'
    end,
    v_subscription.billing_interval_code,
    v_subscription.amount,
    0,
    0,
    0,
    v_subscription.amount,
    coalesce(v_subscription.currency_code, 'USD'),
    coalesce(parent.billing_info, '{}'::jsonb),
    coalesce(parent.shipping_info, '{}'::jsonb),
    jsonb_build_object(
      'subscription',
      jsonb_build_object(
        'subscription_id', v_subscription.id,
        'billing_period_start', v_subscription.period_end,
        'billing_period_end', v_subscription.period_end + v_period,
        'cycle', v_cycle,
        'previous_order_id', v_subscription.latest_order_id,
        'requested_at', p_requested_at
      )
    )
  from (select * from hfcc.commerce_orders where id = v_subscription.latest_order_id) parent
  returning id into v_order_id;

  if v_order_id is null then
    insert into hfcc.commerce_orders (
      user_id,
      order_type_code,
      parent_order_id,
      status_code,
      payment_status_code,
      billing_interval_code,
      subtotal_amount,
      discount_amount,
      tax_amount,
      shipping_amount,
      total_amount,
      currency_code,
      metadata
    )
    values (
      v_subscription.user_id,
      'hfcc.commerce_orders.order_type_code.subscription_renewal',
      v_subscription.latest_order_id,
      'hfcc.commerce_orders.status_code.pending',
      case
        when v_subscription.amount > 0 then 'hfcc.commerce_orders.payment_status_code.pending'
        else 'hfcc.commerce_orders.payment_status_code.paid'
      end,
      v_subscription.billing_interval_code,
      v_subscription.amount,
      0,
      0,
      0,
      v_subscription.amount,
      coalesce(v_subscription.currency_code, 'USD'),
      jsonb_build_object(
        'subscription',
        jsonb_build_object(
          'subscription_id', v_subscription.id,
          'billing_period_start', v_subscription.period_end,
          'billing_period_end', v_subscription.period_end + v_period,
          'cycle', v_cycle,
          'previous_order_id', v_subscription.latest_order_id,
          'requested_at', p_requested_at
        )
      )
    )
    returning id into v_order_id;
  end if;

  insert into hfcc.commerce_order_items (
    order_id,
    product_id,
    subscription_id,
    status_code,
    quantity,
    unit_amount,
    subtotal_amount,
    discount_amount,
    tax_amount,
    total_amount,
    currency_code,
    rules_snapshot,
    entitlements_snapshot,
    payload_snapshot,
    metadata
  )
  select
    v_order_id,
    i.product_id,
    v_subscription.id,
    'hfcc.commerce_order_items.status_code.pending',
    i.quantity,
    i.unit_amount,
    i.subtotal_amount,
    i.discount_amount,
    i.tax_amount,
    i.total_amount,
    i.currency_code,
    i.rules_snapshot,
    i.entitlements_snapshot,
    i.payload_snapshot,
    i.metadata || jsonb_build_object('renewal_source_item_id', i.id)
  from hfcc.commerce_order_items i
  where i.order_id = v_subscription.latest_order_id
    and i.status_code not in (
      'hfcc.commerce_order_items.status_code.cancelled',
      'hfcc.commerce_order_items.status_code.refunded'
    );

  get diagnostics v_inserted_items = row_count;

  if v_inserted_items = 0 then
    raise exception 'Subscription % latest order % has no renewable order items', p_subscription_id, v_subscription.latest_order_id
      using errcode = '23514';
  end if;

  return v_order_id;
end;
$$;

create or replace function hfcc.apply_subscription_renewal_order(
  p_subscription_id uuid,
  p_renewal_order_id uuid,
  p_renewed_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_subscription hfcc.subscriptions%rowtype;
  v_order hfcc.commerce_orders%rowtype;
  v_period interval;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_maintenance jsonb;
begin
  select *
  into v_subscription
  from hfcc.subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Subscription % does not exist', p_subscription_id
      using errcode = '23503';
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_renewal_order_id
  for update;

  if not found then
    raise exception 'Commerce renewal order % does not exist', p_renewal_order_id
      using errcode = '23503';
  end if;

  if v_order.order_type_code <> 'hfcc.commerce_orders.order_type_code.subscription_renewal'
     or not exists (
       select 1
       from hfcc.commerce_order_items i
       where i.order_id = v_order.id
         and i.subscription_id = p_subscription_id
     ) then
    raise exception 'Commerce order % is not a renewal order for subscription %', p_renewal_order_id, p_subscription_id
      using errcode = '23514';
  end if;

  if v_order.status_code not in (
    'hfcc.commerce_orders.status_code.confirmed',
    'hfcc.commerce_orders.status_code.completed'
  ) then
    return jsonb_build_object(
      'subscription_id', p_subscription_id,
      'renewal_order_id', p_renewal_order_id,
      'applied', false,
      'reason_code', 'renewal_order_not_confirmed'
    );
  end if;

  if v_order.total_amount > 0
     and v_order.payment_status_code <> 'hfcc.commerce_orders.payment_status_code.paid' then
    return jsonb_build_object(
      'subscription_id', p_subscription_id,
      'renewal_order_id', p_renewal_order_id,
      'applied', false,
      'reason_code', 'renewal_order_unpaid'
    );
  end if;

  v_period := hfcc.subscription_interval(v_subscription.billing_interval_code);
  v_period_start := coalesce(nullif(v_order.metadata #>> '{subscription,billing_period_start}', '')::timestamptz, v_subscription.period_end);
  v_period_end := coalesce(nullif(v_order.metadata #>> '{subscription,billing_period_end}', '')::timestamptz, v_period_start + v_period);

  update hfcc.subscriptions
  set status_code = 'hfcc.subscriptions.status_code.active',
      payment_status_code = 'hfcc.subscriptions.payment_status_code.paid',
      billing_interval_code = coalesce(v_order.billing_interval_code, billing_interval_code),
      period_start = v_period_start,
      period_end = v_period_end,
      amount = v_order.total_amount,
      currency_code = v_order.currency_code,
      latest_order_id = v_order.id,
      updated_at = now()
  where id = p_subscription_id
  returning * into v_subscription;

  update hfcc.commerce_orders
  set metadata = metadata || jsonb_build_object(
        'subscription',
        coalesce(metadata -> 'subscription', '{}'::jsonb) || jsonb_build_object(
          'renewed_at', p_renewed_at,
          'applied_to_subscription_id', p_subscription_id
        )
      ),
      updated_at = now()
  where id = p_renewal_order_id;

  v_maintenance := hfcc.process_subscription_maintenance(p_subscription_id, p_renewed_at);

  return jsonb_build_object(
    'subscription_id', p_subscription_id,
    'renewal_order_id', p_renewal_order_id,
    'applied', true,
    'period_start', v_period_start,
    'period_end', v_period_end,
    'maintenance', v_maintenance
  );
end;
$$;

create or replace function hfcc.apply_commerce_order_item_entitlements(
  p_order_item_id uuid,
  p_source_account_id uuid default null,
  p_applied_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_item hfcc.commerce_order_items%rowtype;
  v_order hfcc.commerce_orders%rowtype;
  v_product_id uuid;
  v_grant_record record;
  v_grant jsonb;
  v_wallet_grants jsonb;
  v_wallet_grant_id uuid;
  v_wallet_grant_ids jsonb := '[]'::jsonb;
  v_grant_key text;
  v_currency_code text;
  v_amount numeric;
  v_recharge_interval_code text;
  v_recharge_interval interval;
  v_expire_on_next_charge boolean;
  v_user_account_id uuid;
  v_source_account_id uuid;
  v_transaction_id uuid;
  v_transactions jsonb := '[]'::jsonb;
  v_last_charged_at timestamptz;
begin
  select *
  into v_item
  from hfcc.commerce_order_items
  where id = p_order_item_id
  for update;

  if not found then
    raise exception 'Commerce order item % does not exist', p_order_item_id
      using errcode = '23503';
  end if;

  v_product_id := v_item.product_id;

  if v_item.status_code in (
    'hfcc.commerce_order_items.status_code.cancelled',
    'hfcc.commerce_order_items.status_code.refunded'
  ) then
    raise exception 'Commerce order item % cannot receive entitlements in status %', p_order_item_id, v_item.status_code
      using errcode = '23514';
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = v_item.order_id
  for update;

  if not found then
    raise exception 'Commerce order % does not exist', v_item.order_id
      using errcode = '23503';
  end if;

  if v_order.total_amount > 0
     and v_order.payment_status_code <> 'hfcc.commerce_orders.payment_status_code.paid' then
    raise exception 'Commerce order % must be paid before entitlements are applied', v_order.id
      using errcode = '23514';
  end if;

  if not (v_item.entitlements_snapshot ? 'ledger_wallet_grants') then
    return jsonb_build_object('order_item_id', p_order_item_id, 'applied_count', 0, 'transactions', v_transactions);
  end if;

  if jsonb_typeof(v_item.entitlements_snapshot -> 'ledger_wallet_grants') <> 'array' then
    raise exception 'commerce_order_items.entitlements_snapshot.ledger_wallet_grants must be an array'
      using errcode = '23514';
  end if;

  v_wallet_grants := v_item.entitlements_snapshot -> 'ledger_wallet_grants';

  if jsonb_array_length(v_wallet_grants) > 0 then
    perform hfcc.ensure_user_ledger_accounts(v_order.user_id);
  end if;

  for v_grant_record in
    select value, ordinality
    from jsonb_array_elements(v_wallet_grants) with ordinality
  loop
    v_grant := v_grant_record.value;

    if jsonb_typeof(v_grant) <> 'object' then
      raise exception 'Each commerce order item wallet grant must be an object'
        using errcode = '23514';
    end if;

    v_currency_code := v_grant ->> 'currency_code';
    v_grant_key := coalesce(nullif(v_grant ->> 'key', ''), v_currency_code || ':' || v_grant_record.ordinality::text);
    v_amount := nullif(v_grant ->> 'amount', '')::numeric * v_item.quantity;
    v_recharge_interval_code := 'hfcc.ledger_wallet_grants.recharge_interval_code.' || coalesce(v_grant ->> 'recharge_interval', 'once');
    v_recharge_interval := hfcc.subscription_interval(v_recharge_interval_code);
    v_expire_on_next_charge := coalesce((v_grant ->> 'expire_on_next_charge')::boolean, false);

    if v_currency_code is null or v_amount is null or v_amount <= 0 then
      raise exception 'Each commerce wallet grant requires currency_code and positive amount'
        using errcode = '23514';
    end if;

    select la.id
    into v_user_account_id
    from hfcc.ledger_accounts la
    where la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = v_order.user_id
      and la.currency_code = v_currency_code
      and la.account_type_code = 'hfcc.ledger_accounts.account_type_code.user_wallet'
    limit 1;

    if v_user_account_id is null then
      raise exception 'User wallet account for % does not exist', v_currency_code
        using errcode = '23503';
    end if;

    v_source_account_id := coalesce(p_source_account_id, nullif(v_grant ->> 'source_account_id', '')::uuid);

    if v_source_account_id is null then
      select la.id
      into v_source_account_id
      from hfcc.ledger_accounts la
      where la.owner_type = 'hfcc.ledger_accounts.owner_type.system'
        and la.currency_code = v_currency_code
        and la.account_type_code in (
          'hfcc.ledger_accounts.account_type_code.liability',
          'hfcc.ledger_accounts.account_type_code.system'
        )
      order by case la.account_type_code
        when 'hfcc.ledger_accounts.account_type_code.liability' then 1
        when 'hfcc.ledger_accounts.account_type_code.system' then 2
        else 3
      end
      limit 1;
    end if;

    if v_source_account_id is null then
      raise exception 'No source system account found for % commerce wallet grant', v_currency_code
        using errcode = '23503';
    end if;

    insert into hfcc.ledger_wallet_grants (
      user_id,
      source_type,
      source_id,
      grant_key,
      currency_code,
      amount,
      recharge_interval_code,
      expire_on_next_charge,
      source_account_id,
      next_charge_at,
      metadata
    )
    values (
      v_order.user_id,
      'hfcc.ledger_wallet_grants.source_type.commerce_order_item',
      v_item.id,
      v_grant_key,
      v_currency_code,
      v_amount,
      v_recharge_interval_code,
      v_expire_on_next_charge,
      v_source_account_id,
      case when v_recharge_interval is null then null else p_applied_at + v_recharge_interval end,
      jsonb_build_object(
        'commerce_order_id', v_order.id,
        'commerce_order_item_id', v_item.id,
        'commerce_product_id', v_product_id,
        'commerce_ledger_wallet_grant', v_grant,
        'quantity', v_item.quantity
      )
    )
    on conflict (user_id, source_type, source_id, grant_key) do update
    set amount = excluded.amount,
        recharge_interval_code = excluded.recharge_interval_code,
        expire_on_next_charge = excluded.expire_on_next_charge,
        source_account_id = excluded.source_account_id,
        metadata = excluded.metadata,
        status_code = 'hfcc.ledger_wallet_grants.status_code.active',
        updated_at = now()
    returning id, last_charged_at into v_wallet_grant_id, v_last_charged_at;

    v_wallet_grant_ids := v_wallet_grant_ids || jsonb_build_array(v_wallet_grant_id);

    if v_last_charged_at is not null then
      continue;
    end if;

    v_transaction_id := hfcc.create_ledger_transaction(
      'hfcc.ledger_transactions.transaction_code.wallet_grant',
      v_item.id,
      jsonb_build_array(
        jsonb_build_object('account_id', v_source_account_id, 'amount', -v_amount),
        jsonb_build_object('account_id', v_user_account_id, 'amount', v_amount)
      ),
      'Commerce order item wallet grant',
      jsonb_build_object(
        'source_type', 'hfcc.ledger_transactions.source_type.commerce_order_item',
        'commerce_order_id', v_order.id,
        'commerce_order_item_id', v_item.id,
        'commerce_product_id', v_product_id,
        'ledger_wallet_grant_id', v_wallet_grant_id,
        'grant_key', v_grant_key,
        'user_id', v_order.user_id,
        'currency_code', v_currency_code,
        'amount', v_amount,
        'quantity', v_item.quantity,
        'recharge_interval_code', v_recharge_interval_code,
        'expire_on_next_charge', v_expire_on_next_charge
      )
    );

    update hfcc.ledger_wallet_grants
    set last_charged_at = p_applied_at,
        next_charge_at = case when v_recharge_interval is null then null else p_applied_at + v_recharge_interval end,
        last_charge_transaction_id = v_transaction_id,
        updated_at = now()
    where id = v_wallet_grant_id;

    v_transactions := v_transactions || jsonb_build_array(v_transaction_id);
  end loop;

  return jsonb_build_object(
    'order_id', v_order.id,
    'order_item_id', v_item.id,
    'ledger_wallet_grant_ids', v_wallet_grant_ids,
    'ledger_transaction_ids', v_transactions
  );
end;
$$;

create or replace function hfcc.recalculate_commerce_order_totals(p_order_id uuid)
returns hfcc.commerce_orders
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
begin
  if p_order_id is null then
    raise exception 'order_id is required';
  end if;

  update hfcc.commerce_orders o
  set subtotal_amount = totals.subtotal_amount,
      discount_amount = totals.discount_amount,
      tax_amount = totals.tax_amount,
      total_amount = totals.total_amount + o.shipping_amount,
      updated_at = now()
  from (
    select
      coalesce(sum(i.subtotal_amount), 0) as subtotal_amount,
      coalesce(sum(i.discount_amount), 0) as discount_amount,
      coalesce(sum(i.tax_amount), 0) as tax_amount,
      coalesce(sum(i.total_amount), 0) as total_amount
    from hfcc.commerce_order_items i
    where i.order_id = p_order_id
      and i.status_code not in (
        'hfcc.commerce_order_items.status_code.cancelled',
        'hfcc.commerce_order_items.status_code.refunded'
      )
  ) totals
  where o.id = p_order_id
  returning o.* into v_order;

  return v_order;
end;
$$;

create or replace function hfcc.recalculate_commerce_order_payment_status(p_order_id uuid)
returns hfcc.commerce_orders
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
  v_succeeded_amount numeric := 0;
  v_has_open_intent boolean := false;
  v_has_failed_intent boolean := false;
  v_next_payment_status_code text;
begin
  if p_order_id is null then
    raise exception 'order_id is required';
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if not found then
    return null;
  end if;

  if v_order.payment_status_code in (
    'hfcc.commerce_orders.payment_status_code.refunded',
    'hfcc.commerce_orders.payment_status_code.partially_refunded'
  ) then
    return v_order;
  end if;

  select coalesce(sum(pi.amount), 0)
  into v_succeeded_amount
  from hfcc.commerce_payment_intents pi
  where pi.order_id = p_order_id
    and pi.currency_code = v_order.currency_code
    and pi.status_code = 'hfcc.commerce_payment_intents.status_code.succeeded';

  select exists (
    select 1
    from hfcc.commerce_payment_intents pi
    where pi.order_id = p_order_id
      and pi.status_code in (
        'hfcc.commerce_payment_intents.status_code.pending',
        'hfcc.commerce_payment_intents.status_code.requires_action',
        'hfcc.commerce_payment_intents.status_code.processing'
      )
  )
  into v_has_open_intent;

  select exists (
    select 1
    from hfcc.commerce_payment_intents pi
    where pi.order_id = p_order_id
      and pi.status_code = 'hfcc.commerce_payment_intents.status_code.failed'
  )
  into v_has_failed_intent;

  v_next_payment_status_code := case
    when v_order.total_amount = 0 then 'hfcc.commerce_orders.payment_status_code.paid'
    when v_succeeded_amount >= v_order.total_amount then 'hfcc.commerce_orders.payment_status_code.paid'
    when v_succeeded_amount > 0 or v_has_open_intent then 'hfcc.commerce_orders.payment_status_code.pending'
    when v_has_failed_intent then 'hfcc.commerce_orders.payment_status_code.failed'
    else 'hfcc.commerce_orders.payment_status_code.unpaid'
  end;

  update hfcc.commerce_orders
  set payment_status_code = v_next_payment_status_code,
      updated_at = now()
  where id = p_order_id
    and payment_status_code is distinct from v_next_payment_status_code
  returning * into v_order;

  if not found then
    select *
    into v_order
    from hfcc.commerce_orders
    where id = p_order_id;
  end if;

  return v_order;
end;
$$;

create or replace function hfcc.recalculate_commerce_order_status_from_items(p_order_id uuid)
returns hfcc.commerce_orders
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
  v_total_count integer := 0;
  v_completed_count integer := 0;
  v_refunded_count integer := 0;
  v_failed_count integer := 0;
  v_next_status_code text;
begin
  if p_order_id is null then
    raise exception 'order_id is required';
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if not found then
    return null;
  end if;

  if v_order.status_code = 'hfcc.commerce_orders.status_code.cancelled' then
    return v_order;
  end if;

  select
    count(*)::integer,
    count(*) filter (where status_code = 'hfcc.commerce_order_items.status_code.completed')::integer,
    count(*) filter (where status_code = 'hfcc.commerce_order_items.status_code.refunded')::integer,
    count(*) filter (where status_code = 'hfcc.commerce_order_items.status_code.failed')::integer
  into
    v_total_count,
    v_completed_count,
    v_refunded_count,
    v_failed_count
  from hfcc.commerce_order_items
  where order_id = p_order_id
    and status_code <> 'hfcc.commerce_order_items.status_code.cancelled';

  if v_total_count = 0 then
    return v_order;
  end if;

  v_next_status_code := case
    when v_refunded_count = v_total_count then 'hfcc.commerce_orders.status_code.refunded'
    when v_refunded_count > 0 and v_completed_count + v_refunded_count = v_total_count then 'hfcc.commerce_orders.status_code.partially_refunded'
    when v_completed_count = v_total_count then 'hfcc.commerce_orders.status_code.completed'
    when v_failed_count > 0 and v_completed_count + v_refunded_count + v_failed_count = v_total_count then 'hfcc.commerce_orders.status_code.failed'
    else null
  end;

  if v_next_status_code is null or v_order.status_code is not distinct from v_next_status_code then
    return v_order;
  end if;

  if v_next_status_code = 'hfcc.commerce_orders.status_code.completed'
     and v_order.status_code = 'hfcc.commerce_orders.status_code.confirmed'
     and v_order.order_type_code in (
       'hfcc.commerce_orders.order_type_code.subscription_initial',
       'hfcc.commerce_orders.order_type_code.subscription_renewal'
     )
     and coalesce((v_order.metadata #>> '{commerce_processing,subscription_workflow_pending}')::boolean, false) then
    return v_order;
  end if;

  update hfcc.commerce_orders
  set status_code = v_next_status_code,
      updated_at = now()
  where id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

create or replace function hfcc.process_commerce_order(
  p_order_id uuid,
  p_processed_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
  v_item hfcc.commerce_order_items%rowtype;
  v_product_type_code text;
  v_subscription_id uuid;
  v_handler_result jsonb;
  v_subscription_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_error_code text;
  v_error_message text;
begin
  if p_order_id is null then
    raise exception 'order_id is required';
  end if;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Commerce order % does not exist', p_order_id
      using errcode = '23503';
  end if;

  perform hfcc.recalculate_commerce_order_totals(p_order_id);
  perform hfcc.recalculate_commerce_order_payment_status(p_order_id);

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if v_order.total_amount > 0
     and v_order.payment_status_code <> 'hfcc.commerce_orders.payment_status_code.paid' then
    raise exception 'Commerce order % must be paid before processing', p_order_id
      using errcode = '23514';
  end if;

  if v_order.order_type_code in (
    'hfcc.commerce_orders.order_type_code.subscription_initial',
    'hfcc.commerce_orders.order_type_code.subscription_renewal'
  ) then
    update hfcc.commerce_orders
    set metadata = metadata || jsonb_build_object(
          'commerce_processing',
          coalesce(metadata -> 'commerce_processing', '{}'::jsonb) || jsonb_build_object(
            'subscription_workflow_pending', true,
            'started_at', p_processed_at
          )
        ),
        updated_at = now()
    where id = p_order_id
    returning * into v_order;
  end if;

  for v_item in
    select *
    from hfcc.commerce_order_items
    where order_id = p_order_id
      and status_code in (
        'hfcc.commerce_order_items.status_code.pending',
        'hfcc.commerce_order_items.status_code.failed'
      )
    order by created_at, id
    for update
  loop
    v_product_type_code := nullif(coalesce(
      v_item.payload_snapshot #>> '{product,product_type_code}',
      v_item.payload_snapshot ->> 'product_type_code'
    ), '');
    v_handler_result := '{}'::jsonb;
    v_error_code := null;
    v_error_message := null;

    update hfcc.commerce_order_items
    set status_code = 'hfcc.commerce_order_items.status_code.processing',
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'processing',
          jsonb_build_object(
            'started_at', p_processed_at,
            'product_type_code', v_product_type_code
          )
        ),
        updated_at = now()
    where id = v_item.id;

    begin
      if v_product_type_code is null then
        raise exception 'Commerce order item % is missing payload_snapshot.product.product_type_code', v_item.id
          using errcode = '23514';
      end if;

      case v_product_type_code
        when 'hfcc.commerce_products.product_type_code.ledger_wallet_grant' then
          v_handler_result := hfcc.apply_commerce_order_item_entitlements(v_item.id, null, p_processed_at);

        when 'hfcc.commerce_products.product_type_code.bundle' then
          if v_item.entitlements_snapshot ? 'ledger_wallet_grants' then
            v_handler_result := hfcc.apply_commerce_order_item_entitlements(v_item.id, null, p_processed_at);
          else
            v_handler_result := jsonb_build_object('handled_by', 'core_noop');
          end if;

        when 'hfcc.commerce_products.product_type_code.digital' then
          v_handler_result := jsonb_build_object('handled_by', 'core_noop');

        when 'hfcc.commerce_products.product_type_code.physical' then
          v_handler_result := jsonb_build_object('handled_by', 'core_noop');

        when 'hfcc.commerce_products.product_type_code.service' then
          v_handler_result := jsonb_build_object('handled_by', 'core_noop');

        else
          raise exception 'Unsupported commerce product type % for order item %', v_product_type_code, v_item.id
            using errcode = '23514';
      end case;

      update hfcc.commerce_order_items
      set status_code = 'hfcc.commerce_order_items.status_code.completed',
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
            'processing',
            jsonb_build_object(
              'started_at', p_processed_at,
              'finished_at', now(),
              'status_code', 'hfcc.commerce_order_items.status_code.completed',
              'product_type_code', v_product_type_code,
              'result', v_handler_result
            )
          ),
          updated_at = now()
      where id = v_item.id;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'order_item_id', v_item.id,
        'status_code', 'hfcc.commerce_order_items.status_code.completed',
        'product_type_code', v_product_type_code,
        'result', v_handler_result
      ));
    exception
      when others then
        get stacked diagnostics
          v_error_code = returned_sqlstate,
          v_error_message = message_text;

        update hfcc.commerce_order_items
        set status_code = 'hfcc.commerce_order_items.status_code.failed',
            metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
              'processing',
              jsonb_build_object(
                'started_at', p_processed_at,
                'finished_at', now(),
                'status_code', 'hfcc.commerce_order_items.status_code.failed',
                'product_type_code', v_product_type_code,
                'error_code', v_error_code,
                'error_message', v_error_message
              )
            ),
            updated_at = now()
        where id = v_item.id;

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'order_item_id', v_item.id,
          'status_code', 'hfcc.commerce_order_items.status_code.failed',
          'product_type_code', v_product_type_code,
          'error_code', v_error_code,
          'error_message', v_error_message
        ));
    end;
  end loop;

  select *
  into v_order
  from hfcc.commerce_orders
  where id = p_order_id
  for update;

  if v_order.status_code = 'hfcc.commerce_orders.status_code.confirmed'
     and v_order.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_initial'
     and not exists (
       select 1
       from hfcc.commerce_order_items i
       where i.order_id = v_order.id
         and i.status_code <> 'hfcc.commerce_order_items.status_code.completed'
     ) then
    v_subscription_id := hfcc.create_subscription_from_order(v_order.id, p_processed_at);

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'order_id', v_order.id,
      'status_code', 'subscription_workflow_completed',
      'subscription_id', v_subscription_id
    ));
  elsif v_order.status_code = 'hfcc.commerce_orders.status_code.confirmed'
        and v_order.order_type_code = 'hfcc.commerce_orders.order_type_code.subscription_renewal'
        and not exists (
          select 1
          from hfcc.commerce_order_items i
          where i.order_id = v_order.id
            and i.status_code <> 'hfcc.commerce_order_items.status_code.completed'
        ) then
    for v_subscription_id in
      select distinct i.subscription_id
      from hfcc.commerce_order_items i
      where i.order_id = v_order.id
        and i.subscription_id is not null
    loop
      v_subscription_result := hfcc.apply_subscription_renewal_order(v_subscription_id, v_order.id, p_processed_at);
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'order_id', v_order.id,
        'status_code', 'subscription_workflow_completed',
        'subscription_id', v_subscription_id,
        'renewal', v_subscription_result
      ));
    end loop;
  end if;

  if v_order.order_type_code in (
    'hfcc.commerce_orders.order_type_code.subscription_initial',
    'hfcc.commerce_orders.order_type_code.subscription_renewal'
  ) then
    update hfcc.commerce_orders
    set metadata = metadata || jsonb_build_object(
          'commerce_processing',
          coalesce(metadata -> 'commerce_processing', '{}'::jsonb) || jsonb_build_object(
            'subscription_workflow_pending', false,
            'finished_at', now()
          )
        ),
        updated_at = now()
    where id = p_order_id;
  end if;

  perform hfcc.recalculate_commerce_order_status_from_items(p_order_id);

  return jsonb_build_object(
    'order_id', p_order_id,
    'processed_at', p_processed_at,
    'items', v_results
  );
end;
$$;

create or replace function hfcc.after_commerce_order_confirmed()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if new.status_code = 'hfcc.commerce_orders.status_code.confirmed'
     and old.status_code is distinct from new.status_code then
    perform hfcc.process_commerce_order(new.id, now());
  end if;

  return new;
end;
$$;

create or replace trigger after_commerce_order_confirmed
after update of status_code on hfcc.commerce_orders
for each row execute function hfcc.after_commerce_order_confirmed();

create or replace function hfcc.after_commerce_order_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if tg_op = 'DELETE' then
    perform hfcc.recalculate_commerce_order_status_from_items(old.order_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
    perform hfcc.recalculate_commerce_order_status_from_items(old.order_id);
  end if;

  perform hfcc.recalculate_commerce_order_status_from_items(new.order_id);
  return new;
end;
$$;

create or replace trigger after_commerce_order_item_status_change
after insert or update or delete on hfcc.commerce_order_items
for each row execute function hfcc.after_commerce_order_item_status_change();

create or replace function hfcc.after_commerce_order_item_totals_change()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if tg_op = 'DELETE' then
    perform hfcc.recalculate_commerce_order_totals(old.order_id);
    perform hfcc.recalculate_commerce_order_payment_status(old.order_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
    perform hfcc.recalculate_commerce_order_totals(old.order_id);
    perform hfcc.recalculate_commerce_order_payment_status(old.order_id);
  end if;

  perform hfcc.recalculate_commerce_order_totals(new.order_id);
  perform hfcc.recalculate_commerce_order_payment_status(new.order_id);
  return new;
end;
$$;

create or replace trigger after_commerce_order_item_totals_change
after insert or update or delete on hfcc.commerce_order_items
for each row execute function hfcc.after_commerce_order_item_totals_change();

create or replace function hfcc.after_commerce_payment_intent_status_change()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_order hfcc.commerce_orders%rowtype;
begin
  if tg_op = 'DELETE' then
    perform hfcc.recalculate_commerce_order_payment_status(old.order_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
    perform hfcc.recalculate_commerce_order_payment_status(old.order_id);
  end if;

  perform hfcc.recalculate_commerce_order_payment_status(new.order_id);

  select *
  into v_order
  from hfcc.commerce_orders
  where id = new.order_id;

  if found
     and v_order.payment_status_code = 'hfcc.commerce_orders.payment_status_code.paid'
     and v_order.status_code = 'hfcc.commerce_orders.status_code.pending'
     and v_order.order_type_code in (
       'hfcc.commerce_orders.order_type_code.subscription_initial',
       'hfcc.commerce_orders.order_type_code.subscription_renewal'
     ) then
    update hfcc.commerce_orders
    set status_code = 'hfcc.commerce_orders.status_code.confirmed',
        updated_at = now()
    where id = v_order.id;
  end if;

  return new;
end;
$$;

create or replace trigger after_commerce_payment_intent_status_change
after insert or update or delete on hfcc.commerce_payment_intents
for each row execute function hfcc.after_commerce_payment_intent_status_change();

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

create table if not exists hfcc.devices (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references hfcc.users(id) on delete cascade,
  platform_code text not null,
  push_provider_code text,
  push_token text,
  device_name text,
  app_version text,
  last_seen_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint devices_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists devices_unique_push_token_idx
  on hfcc.devices (user_id, push_provider_code, push_token) nulls not distinct
  where push_token is not null;

create index if not exists devices_user_idx on hfcc.devices (user_id, last_seen_at desc);

comment on table hfcc.devices is
  'User devices and push notification endpoints.';

-- ---------------------------------------------------------------------------
-- Outgoing messages
-- ---------------------------------------------------------------------------

create table if not exists hfcc.outgoing_messages (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid references hfcc.users(id) on delete set null,
  channel_code text not null,
  recipient text not null,
  template_code text,
  subject text,
  body text,
  payload jsonb not null default '{}'::jsonb,
  status_code text not null default 'hfcc.outgoing_messages.status_code.pending',
  provider_code text,
  provider_message_id text,
  source_type text,
  source_id uuid,
  send_after timestamptz not null default now(),
  read_at timestamptz,
  sent_at timestamptz,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint outgoing_messages_payload_object_check check (jsonb_typeof(payload) = 'object'),
  constraint outgoing_messages_metadata_object_check check (jsonb_typeof(metadata) = 'object'),
  constraint outgoing_messages_recipient_not_blank_check check (length(btrim(recipient)) > 0)
);

create index if not exists outgoing_messages_user_idx on hfcc.outgoing_messages (user_id, created_at desc);
create index if not exists outgoing_messages_status_idx on hfcc.outgoing_messages (status_code, created_at);
create index if not exists outgoing_messages_provider_message_idx on hfcc.outgoing_messages (provider_code, provider_message_id);
create index if not exists outgoing_messages_due_idx
  on hfcc.outgoing_messages (status_code, send_after)
  where sent_at is null;
create index if not exists outgoing_messages_user_read_idx
  on hfcc.outgoing_messages (user_id, read_at, created_at desc);

comment on table hfcc.outgoing_messages is
  'Provider-agnostic outgoing message requests and delivery state.';

create or replace function hfcc.enqueue_outgoing_message_outbox()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  if new.status_code = 'hfcc.outgoing_messages.status_code.pending' then
    perform hfcc.enqueue_outbox_event(
      'hfcc.events_outbox.event_code.message.send_requested',
      'hfcc.events_outbox.source_type.outgoing_message',
      new.id,
      jsonb_build_object(
        'outgoing_message_id', new.id,
        'user_id', new.user_id,
        'channel_code', new.channel_code,
        'provider_code', new.provider_code,
        'template_code', new.template_code,
        'recipient', new.recipient,
        'send_after', new.send_after,
        'handle_outgoing_message_send_requested', jsonb_build_object(
          'outgoing_message_id', new.id
        )
      ),
      jsonb_build_object('source_table', 'outgoing_messages'),
      new.send_after
    );
  end if;

  return new;
end;
$$;

create or replace trigger enqueue_outgoing_message_outbox
after insert on hfcc.outgoing_messages
for each row execute function hfcc.enqueue_outgoing_message_outbox();

create or replace function hfcc.resolve_outgoing_message_recipient(
  p_user_id uuid,
  p_channel_code text,
  p_provider_code text,
  p_payload jsonb,
  p_step jsonb default '{}'::jsonb
)
returns table(recipient text, device_id uuid)
language plpgsql
security definer
set search_path = hfcc, pg_catalog
as $$
declare
  v_payload_key text;
  v_payload_recipient text;
begin
  v_payload_key := nullif(p_step ->> 'recipient_payload_key', '');
  if v_payload_key is not null then
    v_payload_recipient := nullif(btrim(coalesce(p_payload ->> v_payload_key, '')), '');
    if v_payload_recipient is not null then
      recipient := v_payload_recipient;
      device_id := null;
      return next;
      return;
    end if;
  end if;

  if p_channel_code = 'hfcc.outgoing_messages.channel_code.inapp' then
    recipient := p_user_id::text;
    device_id := null;
    return next;
    return;
  end if;

  if p_channel_code = 'hfcc.outgoing_messages.channel_code.push'
     and p_provider_code = 'hfcc.outgoing_messages.provider_code.fcm' then
    return query
    select d.push_token, d.id
    from hfcc.devices d
    where d.user_id = p_user_id
      and d.push_provider_code = 'hfcc.devices.push_provider_code.fcm'
      and nullif(btrim(coalesce(d.push_token, '')), '') is not null
    order by d.last_seen_at desc nulls last, d.updated_at desc;
    return;
  end if;

  recipient := nullif(btrim(coalesce(p_payload ->> 'recipient', '')), '');
  device_id := null;
  if recipient is not null then
    return next;
  end if;
end;
$$;

create or replace function hfcc.enqueue_message_escalation(
  p_outgoing_message_id uuid,
  p_next_step_index integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = hfcc, pg_catalog
as $$
declare
  v_message hfcc.outgoing_messages%rowtype;
  v_steps jsonb;
  v_step jsonb;
  v_delay_seconds integer;
  v_run_after timestamptz;
  v_event_id uuid;
begin
  select *
  into v_message
  from hfcc.outgoing_messages
  where id = p_outgoing_message_id;

  if not found then
    raise exception 'Outgoing message % does not exist', p_outgoing_message_id
      using errcode = '23503';
  end if;

  v_steps := coalesce(v_message.payload #> '{escalation,steps}', '[]'::jsonb);
  if jsonb_typeof(v_steps) <> 'array'
     or p_next_step_index < 0
     or p_next_step_index >= jsonb_array_length(v_steps) then
    return null;
  end if;

  v_step := v_steps -> p_next_step_index;
  v_delay_seconds := greatest(coalesce((v_step ->> 'delay_seconds')::integer, 0), 0);
  v_run_after := greatest(v_message.created_at + make_interval(secs => v_delay_seconds), now());

  v_event_id := hfcc.enqueue_outbox_event(
    'hfcc.events_outbox.event_code.message.escalation_due',
    'hfcc.events_outbox.source_type.outgoing_message',
    v_message.id,
    jsonb_build_object(
      'outgoing_message_id', v_message.id,
      'step_index', p_next_step_index,
      'handle_outgoing_message_escalation_due', jsonb_build_object(
        'outgoing_message_id', v_message.id,
        'step_index', p_next_step_index
      )
    ),
    jsonb_build_object('source_table', 'outgoing_messages'),
    v_run_after
  );

  return v_event_id;
end;
$$;

create or replace function hfcc.handle_outgoing_message_send_requested(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc, pg_catalog
as $$
declare
  v_message hfcc.outgoing_messages%rowtype;
  v_outgoing_message_id uuid;
  v_escalation_event_id uuid;
begin
  v_outgoing_message_id := coalesce(
    (p_payload ->> 'outgoing_message_id')::uuid,
    (p_payload #>> '{_context,new_row,source_id}')::uuid
  );

  if v_outgoing_message_id is null then
    raise exception 'Message send payload requires outgoing_message_id'
      using errcode = '22023';
  end if;

  select *
  into v_message
  from hfcc.outgoing_messages
  where id = v_outgoing_message_id
  for update;

  if not found then
    raise exception 'Outgoing message % does not exist', v_outgoing_message_id
      using errcode = '23503';
  end if;

  if v_message.status_code <> 'hfcc.outgoing_messages.status_code.pending' then
    return jsonb_build_object('ok', true, 'outgoing_message_id', v_message.id, 'reason', 'not_pending');
  end if;

  if v_message.send_after > now() then
    perform hfcc.enqueue_outbox_event(
      'hfcc.events_outbox.event_code.message.send_requested',
      'hfcc.events_outbox.source_type.outgoing_message',
      v_message.id,
      jsonb_build_object(
        'outgoing_message_id', v_message.id,
        'handle_outgoing_message_send_requested', jsonb_build_object('outgoing_message_id', v_message.id)
      ),
      jsonb_build_object('source_table', 'outgoing_messages', 'reason', 'rescheduled_future_send_after'),
      v_message.send_after
    );

    return jsonb_build_object('ok', true, 'outgoing_message_id', v_message.id, 'reason', 'rescheduled');
  end if;

  if v_message.channel_code = 'hfcc.outgoing_messages.channel_code.inapp' then
    update hfcc.outgoing_messages
    set status_code = 'hfcc.outgoing_messages.status_code.sent',
        provider_code = coalesce(provider_code, 'hfcc.outgoing_messages.provider_code.inapp'),
        provider_message_id = coalesce(provider_message_id, id::text),
        sent_at = coalesce(sent_at, now()),
        error_message = null,
        updated_at = now()
    where id = v_message.id;

    v_escalation_event_id := hfcc.enqueue_message_escalation(v_message.id, 0);

    return jsonb_build_object(
      'ok', true,
      'outgoing_message_id', v_message.id,
      'delivery', 'inapp',
      'escalation_event_id', v_escalation_event_id
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'outgoing_message_id', v_message.id,
    'delivery', 'external_webhook_expected',
    'channel_code', v_message.channel_code,
    'provider_code', v_message.provider_code
  );
end;
$$;

create or replace function hfcc.handle_outgoing_message_escalation_due(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc, pg_catalog
as $$
declare
  v_original hfcc.outgoing_messages%rowtype;
  v_original_id uuid;
  v_new_message_id uuid;
  v_step_index integer;
  v_steps jsonb;
  v_step jsonb;
  v_channel_code text;
  v_provider_code text;
  v_recipient record;
  v_inserted_ids uuid[] := array[]::uuid[];
  v_next_event_id uuid;
begin
  v_original_id := coalesce(
    (p_payload ->> 'outgoing_message_id')::uuid,
    (p_payload #>> '{_context,new_row,source_id}')::uuid
  );
  v_step_index := coalesce((p_payload ->> 'step_index')::integer, 0);

  if v_original_id is null then
    raise exception 'Escalation payload requires outgoing_message_id'
      using errcode = '22023';
  end if;

  select *
  into v_original
  from hfcc.outgoing_messages
  where id = v_original_id;

  if not found then
    raise exception 'Outgoing message % does not exist', v_original_id
      using errcode = '23503';
  end if;

  if v_original.read_at is not null then
    return jsonb_build_object('ok', true, 'outgoing_message_id', v_original.id, 'reason', 'already_read');
  end if;

  v_steps := coalesce(v_original.payload #> '{escalation,steps}', '[]'::jsonb);
  if jsonb_typeof(v_steps) <> 'array'
     or v_step_index < 0
     or v_step_index >= jsonb_array_length(v_steps) then
    return jsonb_build_object('ok', true, 'outgoing_message_id', v_original.id, 'reason', 'no_step');
  end if;

  v_step := v_steps -> v_step_index;
  v_channel_code := v_step ->> 'channel_code';
  v_provider_code := v_step ->> 'provider_code';

  if nullif(v_channel_code, '') is null then
    raise exception 'Escalation step requires channel_code'
      using errcode = '22023';
  end if;

  for v_recipient in
    select *
    from hfcc.resolve_outgoing_message_recipient(
      v_original.user_id,
      v_channel_code,
      v_provider_code,
      v_original.payload,
      v_step
    )
  loop
    if nullif(btrim(coalesce(v_recipient.recipient, '')), '') is null then
      continue;
    end if;

    insert into hfcc.outgoing_messages (
      user_id,
      channel_code,
      recipient,
      template_code,
      subject,
      body,
      payload,
      status_code,
      provider_code,
      source_type,
      source_id,
      send_after,
      metadata
    )
    values (
      v_original.user_id,
      v_channel_code,
      v_recipient.recipient,
      coalesce(v_step ->> 'template_code', v_original.template_code),
      v_original.subject,
      v_original.body,
      (v_original.payload - 'escalation') || jsonb_build_object(
        'escalated_from_message_id', v_original.id,
        'escalation_step_index', v_step_index,
        'device_id', v_recipient.device_id
      ),
      'hfcc.outgoing_messages.status_code.pending',
      v_provider_code,
      coalesce(v_original.source_type, 'hfcc.outgoing_messages.source_type.manual'),
      coalesce(v_original.source_id, v_original.id),
      now(),
      jsonb_build_object(
        'escalated_from_message_id', v_original.id,
        'escalation_step_index', v_step_index
      )
    )
    returning id into v_new_message_id;

    v_inserted_ids := v_inserted_ids || v_new_message_id;
  end loop;

  v_next_event_id := hfcc.enqueue_message_escalation(v_original.id, v_step_index + 1);

  return jsonb_build_object(
    'ok', true,
    'outgoing_message_id', v_original.id,
    'step_index', v_step_index,
    'created_message_ids', to_jsonb(v_inserted_ids),
    'next_event_id', v_next_event_id
  );
end;
$$;

create or replace function hfcc.handle_subscription_renewal_notice_requested(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = hfcc, pg_catalog
as $$
declare
  v_subscription_id uuid;
  v_subscription hfcc.subscriptions%rowtype;
  v_user hfcc.users%rowtype;
  v_template hfcc.types%rowtype;
  v_display_name text;
  v_renewal_date text;
  v_subject text;
  v_body text;
  v_message_id uuid;
begin
  v_subscription_id := coalesce(
    (p_payload ->> 'subscription_id')::uuid,
    (p_payload #>> '{_context,new_row,payload,subscription_id}')::uuid
  );

  if v_subscription_id is null then
    raise exception 'Renewal notice payload requires subscription_id'
      using errcode = '22023';
  end if;

  select *
  into v_subscription
  from hfcc.subscriptions
  where id = v_subscription_id;

  if not found then
    raise exception 'Subscription % does not exist', v_subscription_id
      using errcode = '23503';
  end if;

  select *
  into v_user
  from hfcc.users
  where id = v_subscription.user_id;

  select *
  into v_template
  from hfcc.types
  where code = 'hfcc.outgoing_messages.template_code.subscription_renewal_notice';

  v_display_name := coalesce(nullif(v_user.display_name, ''), 'there');
  v_renewal_date := to_char(v_subscription.period_end at time zone 'UTC', 'YYYY-MM-DD');
  v_subject := coalesce(v_template.metadata ->> 'subject_template', 'Your subscription renews soon');
  v_body := replace(
    replace(
      coalesce(v_template.metadata ->> 'body_template', 'Hi {{display_name}}, your subscription renews on {{renewal_date}}.'),
      '{{display_name}}',
      v_display_name
    ),
    '{{renewal_date}}',
    v_renewal_date
  );

  insert into hfcc.outgoing_messages (
    user_id,
    channel_code,
    recipient,
    template_code,
    subject,
    body,
    payload,
    status_code,
    provider_code,
    source_type,
    source_id,
    send_after,
    metadata
  )
  values (
    v_subscription.user_id,
    coalesce(v_template.metadata ->> 'channel_code', 'hfcc.outgoing_messages.channel_code.inapp'),
    v_subscription.user_id::text,
    'hfcc.outgoing_messages.template_code.subscription_renewal_notice',
    v_subject,
    v_body,
    jsonb_build_object(
      'subscription_id', v_subscription.id,
      'user_id', v_subscription.user_id,
      'display_name', v_display_name,
      'renewal_date', v_renewal_date,
      'period_start', v_subscription.period_start,
      'period_end', v_subscription.period_end,
      'email_recipient', v_user.attributes #>> '{contact,email}',
      'sms_recipient', v_user.attributes #>> '{contact,phone}',
      'escalation', coalesce(v_template.metadata -> 'escalation', '{}'::jsonb)
    ),
    'hfcc.outgoing_messages.status_code.pending',
    coalesce(v_template.metadata ->> 'default_provider_code', 'hfcc.outgoing_messages.provider_code.inapp'),
    'hfcc.outgoing_messages.source_type.subscription',
    v_subscription.id,
    now(),
    jsonb_build_object('source_event', 'subscription.renewal_notice_requested')
  )
  returning id into v_message_id;

  return jsonb_build_object(
    'ok', true,
    'subscription_id', v_subscription.id,
    'outgoing_message_id', v_message_id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Logs
-- ---------------------------------------------------------------------------

create table if not exists hfcc.activity_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_user_id uuid references hfcc.users(id) on delete set null,
  action_code text not null,
  target_type text,
  target_id uuid,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  source_type text,
  source_id uuid,
  created_at timestamptz not null default now(),
  constraint activity_logs_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists activity_logs_actor_idx on hfcc.activity_logs (actor_user_id, created_at desc);
create index if not exists activity_logs_target_idx on hfcc.activity_logs (target_type, target_id, created_at desc);
create index if not exists activity_logs_source_idx on hfcc.activity_logs (source_type, source_id);

comment on table hfcc.activity_logs is
  'User-facing activity log derived from application actions, inbox/outbox processing, jobs, or workers.';

create table if not exists hfcc.audit_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_user_id uuid references hfcc.users(id) on delete set null,
  action_code text not null,
  entity text not null,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  ip_address inet,
  user_agent text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_logs_metadata_object_check check (jsonb_typeof(metadata) = 'object')
);

create index if not exists audit_logs_actor_idx on hfcc.audit_logs (actor_user_id, created_at desc);
create index if not exists audit_logs_entity_idx on hfcc.audit_logs (entity, entity_id, created_at desc);

comment on table hfcc.audit_logs is
  'Service-only audit trail for row-level changes, administrative actions, validation failures, and event handler execution results.';

create or replace function hfcc.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_action_code text;
  v_actor_user_id uuid;
  v_entity_id uuid;
  v_row jsonb;
  v_id_text text;
begin
  if tg_op = 'INSERT' then
    v_action_code := 'hfcc.audit_logs.action_code.insert';
    v_row := to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_action_code := 'hfcc.audit_logs.action_code.update';
    v_row := to_jsonb(new);
  else
    v_action_code := 'hfcc.audit_logs.action_code.delete';
    v_row := to_jsonb(old);
  end if;

  v_id_text := v_row ->> 'id';
  if v_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_entity_id := v_id_text::uuid;
  end if;

  v_actor_user_id := auth.uid();

  insert into hfcc.audit_logs (
    actor_user_id,
    action_code,
    entity,
    entity_id,
    old_data,
    new_data,
    metadata
  )
  values (
    v_actor_user_id,
    v_action_code,
    tg_table_name,
    v_entity_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end,
    jsonb_build_object('schema', tg_table_schema, 'table', tg_table_name)
  );

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create or replace function hfcc.install_audit_trigger(p_table regclass)
returns void
language plpgsql
security definer
set search_path = hfcc
as $$
begin
  execute format('drop trigger if exists audit_row_change on %s', p_table);
  execute format(
    'create trigger audit_row_change after insert or update or delete on %s for each row execute function hfcc.audit_row_change()',
    p_table
  );
end;
$$;

-- Install audit triggers on core tables where user-facing state changes matter.
select hfcc.install_audit_trigger('hfcc.users'::regclass);
select hfcc.install_audit_trigger('hfcc.subscriptions'::regclass);
select hfcc.install_audit_trigger('hfcc.ledger_wallet_grants'::regclass);
select hfcc.install_audit_trigger('hfcc.promotions'::regclass);
select hfcc.install_audit_trigger('hfcc.promotion_usages'::regclass);
select hfcc.install_audit_trigger('hfcc.commerce_products'::regclass);
select hfcc.install_audit_trigger('hfcc.commerce_orders'::regclass);
select hfcc.install_audit_trigger('hfcc.commerce_order_items'::regclass);
select hfcc.install_audit_trigger('hfcc.commerce_payment_methods'::regclass);
select hfcc.install_audit_trigger('hfcc.commerce_payment_intents'::regclass);
select hfcc.install_audit_trigger('hfcc.outgoing_messages'::regclass);
select hfcc.install_audit_trigger('hfcc.ledger_transactions'::regclass);

-- ---------------------------------------------------------------------------
-- Scoped type foreign keys
-- ---------------------------------------------------------------------------
-- Type-bearing columns use normal foreign keys to hfcc.types(code), plus a
-- prefix CHECK so the value must belong to the expected schema.entity.field
-- namespace. hfcc.types itself enforces schema.entity.field.* names.

do $$
declare
  v_spec record;
  v_table regclass;
  v_prefix text;
  v_check_name text;
  v_fk_name text;
begin
  for v_spec in
    select *
    from (values
      ('hfcc.users', 'hfcc', 'role_code', 'users', 'role_code'),
      ('hfcc.settings', 'hfcc', 'scope_type', 'settings', 'scope_type'),
      ('hfcc.media', 'hfcc', 'owner_type', 'media', 'owner_type'),
      ('hfcc.media', 'hfcc', 'media_type_code', 'media', 'media_type_code'),
      ('hfcc.media', 'hfcc', 'storage_provider_code', 'media', 'storage_provider_code'),
      ('hfcc.media_relations', 'hfcc', 'role_code', 'media_relations', 'role_code'),
      ('hfcc.events_outbox', 'hfcc', 'event_code', 'events_outbox', 'event_code'),
      ('hfcc.events_outbox', 'hfcc', 'source_type', 'events_outbox', 'source_type'),
      ('hfcc.events_outbox', 'hfcc', 'status_code', 'events_outbox', 'status_code'),
      ('hfcc.events_inbox', 'hfcc', 'source_code', 'events_inbox', 'source_code'),
      ('hfcc.events_inbox', 'hfcc', 'event_code', 'events_inbox', 'event_code'),
      ('hfcc.events_inbox', 'hfcc', 'status_code', 'events_inbox', 'status_code'),
      ('hfcc.jobs', 'hfcc', 'job_code', 'jobs', 'job_code'),
      ('hfcc.jobs', 'hfcc', 'source_type', 'jobs', 'source_type'),
      ('hfcc.jobs', 'hfcc', 'status_code', 'jobs', 'status_code'),
      ('hfcc.ledger_currencies', 'hfcc', 'type_code', 'ledger_currencies', 'type_code'),
      ('hfcc.ledger_accounts', 'hfcc', 'owner_type', 'ledger_accounts', 'owner_type'),
      ('hfcc.ledger_accounts', 'hfcc', 'account_type_code', 'ledger_accounts', 'account_type_code'),
      ('hfcc.ledger_transactions', 'hfcc', 'transaction_code', 'ledger_transactions', 'transaction_code'),
      ('hfcc.ledger_transactions', 'hfcc', 'source_type', 'ledger_transactions', 'source_type'),
      ('hfcc.ledger_wallet_grants', 'hfcc', 'source_type', 'ledger_wallet_grants', 'source_type'),
      ('hfcc.ledger_wallet_grants', 'hfcc', 'recharge_interval_code', 'ledger_wallet_grants', 'recharge_interval_code'),
      ('hfcc.ledger_wallet_grants', 'hfcc', 'status_code', 'ledger_wallet_grants', 'status_code'),
      ('hfcc.subscriptions', 'hfcc', 'billing_interval_code', 'commerce_orders', 'billing_interval_code'),
      ('hfcc.subscriptions', 'hfcc', 'status_code', 'subscriptions', 'status_code'),
      ('hfcc.subscriptions', 'hfcc', 'payment_status_code', 'subscriptions', 'payment_status_code'),
      ('hfcc.promotions', 'hfcc', 'promotion_type_code', 'promotions', 'promotion_type_code'),
      ('hfcc.promotion_usages', 'hfcc', 'source_type', 'promotion_usages', 'source_type'),
      ('hfcc.commerce_products', 'hfcc', 'product_type_code', 'commerce_products', 'product_type_code'),
      ('hfcc.commerce_products', 'hfcc', 'status_code', 'commerce_products', 'status_code'),
      ('hfcc.commerce_orders', 'hfcc', 'order_type_code', 'commerce_orders', 'order_type_code'),
      ('hfcc.commerce_orders', 'hfcc', 'billing_interval_code', 'commerce_orders', 'billing_interval_code'),
      ('hfcc.commerce_orders', 'hfcc', 'status_code', 'commerce_orders', 'status_code'),
      ('hfcc.commerce_orders', 'hfcc', 'payment_status_code', 'commerce_orders', 'payment_status_code'),
      ('hfcc.commerce_order_items', 'hfcc', 'status_code', 'commerce_order_items', 'status_code'),
      ('hfcc.commerce_payment_methods', 'hfcc', 'provider_code', 'commerce_payment_methods', 'provider_code'),
      ('hfcc.commerce_payment_methods', 'hfcc', 'payment_method_type_code', 'commerce_payment_methods', 'payment_method_type_code'),
      ('hfcc.commerce_payment_intents', 'hfcc', 'provider_code', 'commerce_payment_intents', 'provider_code'),
      ('hfcc.commerce_payment_intents', 'hfcc', 'status_code', 'commerce_payment_intents', 'status_code'),
      ('hfcc.devices', 'hfcc', 'platform_code', 'devices', 'platform_code'),
      ('hfcc.devices', 'hfcc', 'push_provider_code', 'devices', 'push_provider_code'),
      ('hfcc.outgoing_messages', 'hfcc', 'source_type', 'outgoing_messages', 'source_type'),
      ('hfcc.outgoing_messages', 'hfcc', 'channel_code', 'outgoing_messages', 'channel_code'),
      ('hfcc.outgoing_messages', 'hfcc', 'template_code', 'outgoing_messages', 'template_code'),
      ('hfcc.outgoing_messages', 'hfcc', 'status_code', 'outgoing_messages', 'status_code'),
      ('hfcc.outgoing_messages', 'hfcc', 'provider_code', 'outgoing_messages', 'provider_code'),
      ('hfcc.activity_logs', 'hfcc', 'action_code', 'activity_logs', 'action_code'),
      ('hfcc.activity_logs', 'hfcc', 'source_type', 'activity_logs', 'source_type'),
      ('hfcc.audit_logs', 'hfcc', 'action_code', 'audit_logs', 'action_code')
    ) as s(table_name, type_schema, column_name, entity, field)
  loop
    v_table := v_spec.table_name::regclass;
    v_prefix := v_spec.type_schema || '.' || v_spec.entity || '.' || v_spec.field || '.';
    v_check_name := v_spec.entity || '_' || v_spec.field || '_scope_check';
    v_fk_name := v_spec.entity || '_' || v_spec.field || '_type_fk';

    if not exists (
      select 1
      from pg_constraint
      where conrelid = v_table
        and conname = v_check_name
    ) then
      execute format(
        'alter table %s add constraint %I check (%I is null or left(%I, %s) = %L)',
        v_table,
        v_check_name,
        v_spec.column_name,
        v_spec.column_name,
        length(v_prefix),
        v_prefix
      );
    end if;

    if not exists (
      select 1
      from pg_constraint
      where conrelid = v_table
        and conname = v_fk_name
    ) then
      execute format(
        'alter table %s add constraint %I foreign key (%I) references hfcc.types(code)',
        v_table,
        v_fk_name,
        v_spec.column_name
      );
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Schema documentation comments
-- ---------------------------------------------------------------------------
-- These comments are stored in PostgreSQL metadata and are visible through
-- Supabase Studio, pg_catalog, and schema introspection tools.

comment on function hfcc.is_valid_type(text, text, text, text) is
  'Returns true when a code is active and scoped to the requested schema, entity, and field.';
comment on function hfcc.is_valid_type(text, text, text) is
  'Returns true when a code is active and scoped to hfcc schema plus the requested entity and field.';
comment on function hfcc.handle_new_auth_user() is
  'Auth trigger function that creates a HFCC user row and user ledger accounts for active currencies.';
comment on function hfcc.enqueue_outbox_event(text, text, uuid, jsonb, jsonb, timestamptz) is
  'Appends a pending outbox event for asynchronous integration or side-effect processing.';
comment on function hfcc.claim_due_jobs(integer) is
  'Atomically claims due pending jobs with FOR UPDATE SKIP LOCKED and marks them processing.';
comment on function hfcc.handle_job_subscription_maintenance_daily(jsonb) is
  'Job handler for daily subscription maintenance jobs. Receives the nested payload resolved from types.invoke_functions and expects subscription_id.';
comment on function hfcc.handle_job_subscription_expire(jsonb) is
  'Job handler for subscription expiration jobs. Receives the nested payload resolved from types.invoke_functions and expects subscription_id.';
comment on function hfcc.handle_job_subscription_activate(jsonb) is
  'Job handler for starting subscription renewal payment. Receives the nested payload resolved from types.invoke_functions and expects subscription_id.';
comment on function hfcc.handle_job_subscription_renewal_notice(jsonb) is
  'Job handler for subscription renewal notice jobs. Receives the nested payload resolved from types.invoke_functions and expects subscription_id.';
comment on function hfcc.handle_outgoing_message_send_requested(jsonb) is
  'Outbox event handler for outgoing message send requests. In-app messages are marked sent internally; external messages are left for provider webhooks or edge functions.';
comment on function hfcc.handle_outgoing_message_escalation_due(jsonb) is
  'Outbox event handler that checks whether an in-app message remains unread and creates the next configured outgoing message channel.';
comment on function hfcc.handle_subscription_renewal_notice_requested(jsonb) is
  'Outbox event handler that turns subscription renewal notice requests into outgoing in-app messages with configured escalation steps.';
comment on function hfcc.resolve_outgoing_message_recipient(uuid, text, text, jsonb, jsonb) is
  'Resolves provider-specific recipients for outgoing message channels, including FCM tokens from hfcc.devices.';
comment on function hfcc.enqueue_message_escalation(uuid, integer) is
  'Schedules the next unread-message escalation step as an events_outbox row.';
comment on function hfcc.process_due_jobs(integer) is
  'Claims due jobs. The status change to processing is handled by core_after_type_dispatch using job_code invoke functions configured in hfcc.types.invoke_functions.';
comment on function hfcc.claim_due_events_outbox(integer) is
  'Atomically claims due pending outbox events with FOR UPDATE SKIP LOCKED and marks them processing.';
comment on function hfcc.process_due_events_outbox(integer) is
  'Claims due outbox events. The status change to processing is handled by core_after_type_dispatch using event_code invoke functions configured in hfcc.types.invoke_functions.';
comment on function hfcc.retry_stuck_jobs(interval) is
  'Requeues processing jobs whose locks are stale and whose maximum attempts are not exhausted.';
comment on function hfcc.retry_stuck_events_outbox(interval) is
  'Requeues processing outbox events whose locks are stale and whose maximum attempts are not exhausted.';
comment on function hfcc.ensure_hfcc_user(uuid) is
  'Idempotent insert into hfcc.users for the given auth user id. No-ops if the row already exists. Use before ensure_user_ledger_accounts when the caller may be a pre-HFCC user.';
comment on function hfcc.ensure_user_ledger_accounts(uuid) is
  'Creates one user wallet ledger account for each active ledger currency and is safe to call repeatedly.';
comment on function hfcc.assert_ledger_transaction_balanced(uuid) is
  'Validates that a ledger transaction has at least two entries, balances to zero for each currency, and does not overdraw non-system accounts for currencies that disallow negative balances.';
comment on function hfcc.assert_non_system_balances_allowed(uuid) is
  'Rejects negative balances for non-system ledger accounts when their currency disallows negative balances.';
comment on function hfcc.validate_ledger_entries_balance_trigger() is
  'Deferred constraint trigger function that validates ledger balance after ledger entry inserts, updates, and deletes.';
comment on function hfcc.validate_ledger_transaction_balance_trigger() is
  'Deferred constraint trigger function that validates ledger balance after ledger transaction inserts and updates.';
comment on function hfcc.create_ledger_transaction(text, uuid, jsonb, text, jsonb) is
  'Creates a ledger transaction and entries from JSON, validates account existence, and enforces double-entry balance.';
comment on function hfcc.spend_user_balance(uuid, text, numeric, uuid, uuid, text, jsonb) is
  'Debits a user wallet and credits an explicit or default system destination account for the same currency.';
comment on function hfcc.prevent_immutable_subscription_update() is
  'Blocks non-service updates to historical paid subscriptions once they are expired or cancelled.';
comment on function hfcc.subscription_interval(text) is
  'Maps commerce order billing interval and wallet-grant recharge interval type codes to PostgreSQL intervals.';
comment on function hfcc.schedule_subscription_lifecycle_jobs(uuid, boolean) is
  'Creates lifecycle jobs for a subscription: daily maintenance, expiration, renewal payment start, and renewal notice.';
comment on function hfcc.activate_scheduled_subscription(uuid, timestamptz) is
  'Finds or creates the current renewal order, creates a payment intent when payment is due, and pauses the subscription until the renewal order completes.';
comment on function hfcc.enqueue_subscription_renewal_notice(uuid, timestamptz) is
  'Creates a generic outbox request for app-specific subscription renewal notice delivery.';
comment on function hfcc.create_subscription_from_order(uuid, timestamptz) is
  'Creates a long-lived subscription from a confirmed paid subscription_initial commerce order. Orders and order items retain product snapshots; order completion remains based on order item status.';
comment on function hfcc.create_subscription_renewal_order(uuid, timestamptz) is
  'Creates or returns the pending commerce renewal order for the next subscription cycle and stores billing-period details in order metadata.';
comment on function hfcc.apply_subscription_renewal_order(uuid, uuid, timestamptz) is
  'Applies a confirmed paid commerce renewal order to the existing subscription, advances the subscription period, reactivates it, and schedules the next renewal cycle. Order completion remains based on order item status.';
comment on function hfcc.apply_subscription_entitlements(uuid, uuid, timestamptz, boolean) is
  'Compatibility scheduler for subscription lifecycle jobs. Product entitlements are applied from commerce order items, not stored on subscriptions.';
comment on function hfcc.after_subscription_activation() is
  'Subscription trigger function that schedules lifecycle jobs when an existing subscription becomes active and paid after a renewal.';
comment on function hfcc.process_subscription_maintenance(uuid, timestamptz) is
  'Runs subscription maintenance: reconciles non-rollover wallet grants, recharges due wallet grants, expires ended subscriptions, and reschedules lifecycle jobs.';
comment on function hfcc.validate_promotion_for_user(uuid, text, text, uuid, uuid) is
  'Checks whether a promotion code or promotion id is usable by a user and returns validity details without mutating data.';
comment on function hfcc.apply_promotion(uuid, text, text, uuid, text, uuid, uuid) is
  'Applies a valid promotion code, records usage, creates ledger_wallet_grants from promotions.rules.ledger_wallet_grants, and posts the grant transactions.';
comment on function hfcc.apply_commerce_order_item_entitlements(uuid, uuid, timestamptz) is
  'Creates ledger_wallet_grants from commerce_order_items.entitlements_snapshot.ledger_wallet_grants and posts the first grant transactions for paid or free commerce orders.';
comment on function hfcc.recalculate_commerce_order_totals(uuid) is
  'Recalculates commerce order subtotal, discount, tax, and final total from non-cancelled, non-refunded order items while preserving order-level shipping.';
comment on function hfcc.recalculate_commerce_order_payment_status(uuid) is
  'Recalculates commerce order payment status from succeeded payment intents. Marks the order paid when succeeded intent totals reach the order total.';
comment on function hfcc.recalculate_commerce_order_status_from_items(uuid) is
  'Derives commerce order lifecycle status from order item statuses: completed, refunded, partially refunded, or failed.';
comment on function hfcc.process_commerce_order(uuid, timestamptz) is
  'Processes a confirmed commerce order by dispatching each pending or failed item by snapshotted product type, then creates or renews subscriptions for subscription orders.';
comment on function hfcc.after_commerce_order_confirmed() is
  'Order trigger function that processes an order when its status changes to confirmed.';
comment on function hfcc.after_commerce_order_item_status_change() is
  'Order-item trigger function that derives parent order status after item status changes.';
comment on function hfcc.after_commerce_order_item_totals_change() is
  'Order-item trigger function that recalculates parent commerce order totals after order item inserts, updates, deletes, or order reassignment.';
comment on function hfcc.after_commerce_payment_intent_status_change() is
  'Payment-intent trigger function that recalculates parent commerce order payment status after payment intent inserts, updates, deletes, or order reassignment.';
comment on function hfcc.validate_promotion_usage() is
  'Validates promotion activity window, global max uses, and per-user limits before recording usage.';
comment on function hfcc.after_promotion_usage_insert() is
  'Updates promotion usage counters after a promotion usage is inserted.';
comment on function hfcc.enqueue_outgoing_message_outbox() is
  'Creates an outbox send request when an outgoing message is inserted in pending status.';
comment on function hfcc.audit_row_change() is
  'Reusable audit trigger function that records row inserts, updates, and deletes into audit_logs.';
comment on function hfcc.install_audit_trigger(regclass) is
  'Installs the reusable audit_row_change trigger on a target table.';

comment on column hfcc.types.code is 'Namespaced primary key for a reusable type, status, channel, event, or category value.';
comment on column hfcc.types.schema is 'Logical schema namespace for the code. Codes must start with schema.entity.field.';
comment on column hfcc.types.entity is 'Logical table or domain entity that owns this type code.';
comment on column hfcc.types.field is 'Column or semantic field where this code is valid.';
comment on column hfcc.types.label is 'Human-readable label for UI and administration.';
comment on column hfcc.types.description is 'Optional longer explanation of the code purpose.';
comment on column hfcc.types.invoke_functions is 'Ordered JSON array of HFCC handler functions to invoke. Each entry may include function_name, payload_key, and payload.';
comment on column hfcc.types.log_audit is 'When true, applying this type code writes a structured audit_logs row through the generic dispatcher.';
comment on column hfcc.types.log_activity is 'When true, applying this type code writes a structured activity_logs row through the generic dispatcher.';
comment on column hfcc.types.metadata is 'Additional structured metadata for the code.';
comment on column hfcc.types.is_active is 'Whether this code is active for UI/admin selection. Foreign keys preserve historical inactive values.';
comment on column hfcc.types.sort_order is 'Ordering hint for UI lists and administration screens.';
comment on column hfcc.types.created_at is 'Timestamp when the type row was created.';
comment on column hfcc.types.updated_at is 'Timestamp when the type row was last updated.';

comment on column hfcc.json_schemas.id is 'Primary key for a JSON schema version.';
comment on column hfcc.json_schemas.entity is 'Entity name whose JSON field is validated by this schema.';
comment on column hfcc.json_schemas.field is 'JSONB field name validated by this schema, usually attributes.';
comment on column hfcc.json_schemas.version is 'Monotonic version number for the entity and field schema.';
comment on column hfcc.json_schemas.json_schema is 'JSON Schema-like validator document used by the unified core_before_write trigger.';
comment on column hfcc.json_schemas.is_active is 'Whether this schema version is eligible for validation.';
comment on column hfcc.json_schemas.created_at is 'Timestamp when the schema row was created.';
comment on column hfcc.json_schemas.updated_at is 'Timestamp when the schema row was last updated.';

comment on column hfcc.users.id is 'Primary UUID for the HFCC user row. Auth-created rows use the same id as auth.users.id, without a database FK.';
comment on column hfcc.users.display_name is 'User-facing display name.';
comment on column hfcc.users.role_code is 'Validated HFCC user role code from hfcc.types. Only service role may change this value.';
comment on column hfcc.users.avatar_media_id is 'Optional media object used as the user avatar.';
comment on column hfcc.users.attributes is 'Validated flexible HFCC user attributes stored as JSONB.';
comment on column hfcc.users.created_at is 'Timestamp when the HFCC user row was created.';
comment on column hfcc.users.updated_at is 'Timestamp when the HFCC user row was last updated.';

comment on column hfcc.media.id is 'Primary key for a media object.';
comment on column hfcc.media.owner_type is 'Validated owner type code from hfcc.types, such as hfcc.media.owner_type.user or hfcc.media.owner_type.system.';
comment on column hfcc.media.owner_id is 'Polymorphic owner identifier matching the validated owner_type.';
comment on column hfcc.media.file_name is 'Original or display file name.';
comment on column hfcc.media.mime_type is 'MIME type reported for the stored object.';
comment on column hfcc.media.media_type_code is 'Validated media type code from hfcc.types.';
comment on column hfcc.media.storage_provider_code is 'Validated storage provider code from hfcc.types.';
comment on column hfcc.media.storage_key is 'Provider-specific storage key or object path.';
comment on column hfcc.media.file_size is 'File size in bytes when known.';
comment on column hfcc.media.width is 'Pixel width for image or video media when known.';
comment on column hfcc.media.height is 'Pixel height for image or video media when known.';
comment on column hfcc.media.duration_seconds is 'Duration in seconds for audio or video media when known.';
comment on column hfcc.media.attributes is 'Validated flexible media attributes stored as JSONB.';
comment on column hfcc.media.metadata is 'Unvalidated operational metadata for storage and processing.';
comment on column hfcc.media.created_at is 'Timestamp when the media row was created.';
comment on column hfcc.media.updated_at is 'Timestamp when the media row was last updated.';

comment on column hfcc.media_relations.id is 'Primary key for a media relation.';
comment on column hfcc.media_relations.media_id is 'Referenced media object.';
comment on column hfcc.media_relations.entity is 'Polymorphic target entity name.';
comment on column hfcc.media_relations.entity_id is 'Polymorphic target entity identifier.';
comment on column hfcc.media_relations.role_code is 'Validated relation role code from hfcc.types.';
comment on column hfcc.media_relations.sort_order is 'Ordering hint for multiple media objects on the same entity.';
comment on column hfcc.media_relations.created_at is 'Timestamp when the relation row was created.';

comment on column hfcc.settings.id is 'Primary key for a scoped setting.';
comment on column hfcc.settings.scope_type is 'Validated setting scope type code from hfcc.types, such as hfcc.settings.scope_type.global, hfcc.settings.scope_type.user, or hfcc.settings.scope_type.app.';
comment on column hfcc.settings.scope_id is 'Optional identifier for the scoped owner.';
comment on column hfcc.settings.key is 'Setting key unique within the scope.';
comment on column hfcc.settings.value is 'JSONB value for the setting.';
comment on column hfcc.settings.is_public is 'Whether the setting may be read by public or authenticated clients through RLS.';
comment on column hfcc.settings.created_at is 'Timestamp when the setting was created.';
comment on column hfcc.settings.updated_at is 'Timestamp when the setting was last updated.';

comment on column hfcc.events_outbox.id is 'Primary key for an outbox event.';
comment on column hfcc.events_outbox.event_code is 'Validated outbox event code from hfcc.types.';
comment on column hfcc.events_outbox.source_type is 'Optional source entity type that requested this outbox side effect.';
comment on column hfcc.events_outbox.source_id is 'Optional source entity id that requested this outbox side effect.';
comment on column hfcc.events_outbox.payload is 'Payload to deliver or process externally.';
comment on column hfcc.events_outbox.metadata is 'Operational metadata for outbox processing.';
comment on column hfcc.events_outbox.status_code is 'Validated outbox processing status code from hfcc.types.';
comment on column hfcc.events_outbox.attempt_count is 'Number of processing attempts already made.';
comment on column hfcc.events_outbox.max_attempts is 'Maximum processing attempts allowed.';
comment on column hfcc.events_outbox.run_after is 'Earliest timestamp when the event may be claimed.';
comment on column hfcc.events_outbox.locked_at is 'Timestamp when a worker claimed the event.';
comment on column hfcc.events_outbox.processed_at is 'Timestamp when outbox processing completed.';
comment on column hfcc.events_outbox.error_message is 'Last processing error message.';
comment on column hfcc.events_outbox.created_at is 'Timestamp when the outbox row was created.';
comment on column hfcc.events_outbox.updated_at is 'Timestamp when the outbox row was last updated.';

comment on column hfcc.events_inbox.id is 'Primary key for an inbox event.';
comment on column hfcc.events_inbox.source_code is 'Validated external source code from hfcc.types.';
comment on column hfcc.events_inbox.external_event_id is 'External provider event identifier used for idempotency.';
comment on column hfcc.events_inbox.event_code is 'Validated inbox event code from hfcc.types.';
comment on column hfcc.events_inbox.payload is 'External event payload.';
comment on column hfcc.events_inbox.metadata is 'Operational metadata for inbox processing.';
comment on column hfcc.events_inbox.status_code is 'Validated inbox processing status code from hfcc.types.';
comment on column hfcc.events_inbox.processed_at is 'Timestamp when inbox processing completed.';
comment on column hfcc.events_inbox.error_message is 'Last processing error message.';
comment on column hfcc.events_inbox.created_at is 'Timestamp when the inbox row was created.';
comment on column hfcc.events_inbox.updated_at is 'Timestamp when the inbox row was last updated.';

comment on column hfcc.jobs.id is 'Primary key for a scheduled or deferred job.';
comment on column hfcc.jobs.job_code is 'Validated job code from hfcc.types.';
comment on column hfcc.jobs.source_type is 'Optional source entity type that requested the job.';
comment on column hfcc.jobs.source_id is 'Optional source entity id that requested the job.';
comment on column hfcc.jobs.payload is 'Job input payload. If it contains an object property named like an invoke_functions payload_key, that nested object is passed to the function; otherwise the invoke_functions payload is used. The generic invoker always appends _context.';
comment on column hfcc.jobs.status_code is 'Validated job processing status code from hfcc.types.';
comment on column hfcc.jobs.attempt_count is 'Number of processing attempts already made.';
comment on column hfcc.jobs.max_attempts is 'Maximum processing attempts allowed.';
comment on column hfcc.jobs.run_after is 'Earliest timestamp when the job may be claimed.';
comment on column hfcc.jobs.locked_at is 'Timestamp when a worker claimed the job.';
comment on column hfcc.jobs.processed_at is 'Timestamp when job processing completed.';
comment on column hfcc.jobs.error_message is 'Last processing error message.';
comment on column hfcc.jobs.created_at is 'Timestamp when the job row was created.';
comment on column hfcc.jobs.updated_at is 'Timestamp when the job row was last updated.';

comment on column hfcc.ledger_currencies.code is 'Primary key currency code for fiat, points, credits, tokens, or app-specific units.';
comment on column hfcc.ledger_currencies.name is 'Human-readable currency name.';
comment on column hfcc.ledger_currencies.type_code is 'Validated currency type code from hfcc.types.';
comment on column hfcc.ledger_currencies.precision is 'Number of fractional decimal places supported by this currency.';
comment on column hfcc.ledger_currencies.allow_negative_balance is 'Whether non-system ledger accounts may hold a negative balance in this currency; system accounts are exempt.';
comment on column hfcc.ledger_currencies.is_convertible is 'Whether this currency can be converted to USD using usd_rate.';
comment on column hfcc.ledger_currencies.usd_rate is 'Optional conversion rate to USD.';
comment on column hfcc.ledger_currencies.metadata is 'Operational and display metadata for the currency.';
comment on column hfcc.ledger_currencies.is_active is 'Whether the currency is active for new accounts and transactions.';
comment on column hfcc.ledger_currencies.created_at is 'Timestamp when the currency row was created.';
comment on column hfcc.ledger_currencies.updated_at is 'Timestamp when the currency row was last updated.';

comment on column hfcc.ledger_accounts.id is 'Primary key for a ledger account.';
comment on column hfcc.ledger_accounts.owner_type is 'Validated owner type code from hfcc.types, such as hfcc.ledger_accounts.owner_type.user or hfcc.ledger_accounts.owner_type.system.';
comment on column hfcc.ledger_accounts.owner_id is 'Polymorphic owner identifier matching the validated owner_type.';
comment on column hfcc.ledger_accounts.currency_code is 'Currency code for this ledger account.';
comment on column hfcc.ledger_accounts.account_type_code is 'Validated ledger account type code from hfcc.types.';
comment on column hfcc.ledger_accounts.name is 'Optional display name for the ledger account.';
comment on column hfcc.ledger_accounts.metadata is 'Operational metadata for the ledger account.';
comment on column hfcc.ledger_accounts.created_at is 'Timestamp when the ledger account was created.';
comment on column hfcc.ledger_accounts.updated_at is 'Timestamp when the ledger account was last updated.';

comment on column hfcc.ledger_transactions.id is 'Primary key for a ledger transaction header.';
comment on column hfcc.ledger_transactions.source_type is 'Optional source entity type associated with this ledger transaction.';
comment on column hfcc.ledger_transactions.source_id is 'Optional source entity id associated with this ledger transaction.';
comment on column hfcc.ledger_transactions.transaction_code is 'Validated ledger transaction code from hfcc.types.';
comment on column hfcc.ledger_transactions.description is 'Optional human-readable transaction description.';
comment on column hfcc.ledger_transactions.metadata is 'Operational metadata for the ledger transaction.';
comment on column hfcc.ledger_transactions.fx_rate_used is 'Optional foreign exchange rate used for reporting or conversion.';
comment on column hfcc.ledger_transactions.base_amount_usd is 'Optional base USD amount used for reporting.';
comment on column hfcc.ledger_transactions.created_at is 'Timestamp when the ledger transaction was created.';

comment on column hfcc.ledger_entries.id is 'Primary key for a ledger entry line.';
comment on column hfcc.ledger_entries.transaction_id is 'Ledger transaction that owns this entry.';
comment on column hfcc.ledger_entries.account_id is 'Ledger account credited or debited by this entry.';
comment on column hfcc.ledger_entries.amount is 'Entry amount; positive credits the account and negative debits the account.';
comment on column hfcc.ledger_entries.created_at is 'Timestamp when the ledger entry was created.';

comment on column hfcc.subscriptions.id is 'Primary key for a subscription period row.';
comment on column hfcc.subscriptions.user_id is 'HFCC user that owns the subscription.';
comment on column hfcc.subscriptions.payment_method_id is 'Saved user payment method used by default for renewal payment intents.';
comment on column hfcc.subscriptions.billing_interval_code is 'Billing interval snapshot from the commerce order that created or renewed the subscription.';
comment on column hfcc.subscriptions.initial_order_id is 'First commerce order that created this long-lived subscription.';
comment on column hfcc.subscriptions.latest_order_id is 'Latest commerce order applied to this subscription, usually the latest paid renewal order.';
comment on column hfcc.subscriptions.status_code is 'Validated subscription status code from hfcc.types.';
comment on column hfcc.subscriptions.period_start is 'Inclusive subscription period start timestamp.';
comment on column hfcc.subscriptions.period_end is 'Exclusive subscription period end timestamp.';
comment on column hfcc.subscriptions.auto_renew is 'Whether the subscription should renew automatically.';
comment on column hfcc.subscriptions.payment_status_code is 'Validated payment status code from hfcc.types.';
comment on column hfcc.subscriptions.amount is 'Amount charged or expected for this subscription period.';
comment on column hfcc.subscriptions.currency_code is 'Plain text currency code used for amount; non-ledger tables intentionally do not FK to ledger_currencies.';
comment on column hfcc.subscriptions.attributes is 'Validated flexible subscription attributes stored as JSONB.';
comment on column hfcc.subscriptions.created_at is 'Timestamp when the subscription row was created.';
comment on column hfcc.subscriptions.updated_at is 'Timestamp when the subscription row was last updated.';

comment on column hfcc.ledger_wallet_grants.id is 'Primary key for an instantiated wallet grant.';
comment on column hfcc.ledger_wallet_grants.user_id is 'HFCC user receiving the wallet grant.';
comment on column hfcc.ledger_wallet_grants.source_type is 'Validated source type for the grant, such as subscription, commerce order item, promotion usage, or manual.';
comment on column hfcc.ledger_wallet_grants.source_id is 'Optional source row id for the grant.';
comment on column hfcc.ledger_wallet_grants.grant_key is 'Stable grant key unique within the user/source pair.';
comment on column hfcc.ledger_wallet_grants.currency_code is 'Currency granted to the user wallet.';
comment on column hfcc.ledger_wallet_grants.amount is 'Amount granted on each charge cycle.';
comment on column hfcc.ledger_wallet_grants.recharge_interval_code is 'Validated recharge interval code from hfcc.types.';
comment on column hfcc.ledger_wallet_grants.expire_on_next_charge is 'When true, unused granted value is deducted before the next recharge or at subscription expiry.';
comment on column hfcc.ledger_wallet_grants.source_account_id is 'Ledger account funding this wallet grant.';
comment on column hfcc.ledger_wallet_grants.last_charged_at is 'Timestamp of the most recent wallet grant charge.';
comment on column hfcc.ledger_wallet_grants.next_charge_at is 'Next timestamp when this wallet grant should be recharged.';
comment on column hfcc.ledger_wallet_grants.last_charge_transaction_id is 'Ledger transaction for the most recent wallet grant charge.';
comment on column hfcc.ledger_wallet_grants.status_code is 'Validated wallet grant lifecycle status code from hfcc.types.';
comment on column hfcc.ledger_wallet_grants.metadata is 'Operational metadata including the source ledger_wallet_grant JSON.';
comment on column hfcc.ledger_wallet_grants.created_at is 'Timestamp when the wallet grant row was created.';
comment on column hfcc.ledger_wallet_grants.updated_at is 'Timestamp when the wallet grant row was last updated.';

comment on column hfcc.promotions.id is 'Primary key for a promotion.';
comment on column hfcc.promotions.code is 'Optional user-facing coupon, referral, or promotion code.';
comment on column hfcc.promotions.promotion_type_code is 'Validated promotion type code from hfcc.types.';
comment on column hfcc.promotions.campaign_code is 'Optional campaign grouping code.';
comment on column hfcc.promotions.campaign_name is 'Optional campaign display name.';
comment on column hfcc.promotions.created_by_user_id is 'HFCC user that created the promotion when applicable.';
comment on column hfcc.promotions.max_uses is 'Optional global usage limit for the promotion.';
comment on column hfcc.promotions.used_count is 'Number of recorded usages for this promotion.';
comment on column hfcc.promotions.per_user_limit is 'Optional maximum number of usages per user.';
comment on column hfcc.promotions.starts_at is 'Optional timestamp when the promotion becomes active.';
comment on column hfcc.promotions.expires_at is 'Optional timestamp when the promotion expires.';
comment on column hfcc.promotions.rules is 'Validated promotion behavior configuration for eligibility, discounts, limits, and ledger_wallet_grants.';
comment on column hfcc.promotions.attributes is 'Validated flexible promotion attributes stored as JSONB.';
comment on column hfcc.promotions.is_active is 'Whether the promotion is active for new usage.';
comment on column hfcc.promotions.created_at is 'Timestamp when the promotion was created.';
comment on column hfcc.promotions.updated_at is 'Timestamp when the promotion was last updated.';

comment on column hfcc.promotion_usages.id is 'Primary key for a promotion usage record.';
comment on column hfcc.promotion_usages.promotion_id is 'Promotion that was used.';
comment on column hfcc.promotion_usages.user_id is 'HFCC user that used the promotion.';
comment on column hfcc.promotion_usages.context_type is 'Optional polymorphic context type for idempotent usage.';
comment on column hfcc.promotion_usages.context_id is 'Optional polymorphic context identifier for idempotent usage.';
comment on column hfcc.promotion_usages.source_type is 'Optional source entity type that requested promotion usage.';
comment on column hfcc.promotion_usages.source_id is 'Optional source entity id that requested promotion usage.';
comment on column hfcc.promotion_usages.created_at is 'Timestamp when the promotion usage was created.';

comment on column hfcc.commerce_products.id is 'Primary key for a reusable commerce product.';
comment on column hfcc.commerce_products.name is 'Human-readable product name.';
comment on column hfcc.commerce_products.description is 'Optional product description.';
comment on column hfcc.commerce_products.product_type_code is 'Validated commerce product type code from hfcc.types.';
comment on column hfcc.commerce_products.status_code is 'Validated commerce product lifecycle status code from hfcc.types.';
comment on column hfcc.commerce_products.price_amount is 'Base product price amount.';
comment on column hfcc.commerce_products.price_currency_code is 'Plain text currency code for the base product price; non-ledger tables intentionally do not FK to ledger_currencies.';
comment on column hfcc.commerce_products.taxable is 'Whether the product is taxable by default.';
comment on column hfcc.commerce_products.attributes is 'Product attributes for UI display, categorization, subscription flags, and app-specific presentation concerns. Not used for commerce processing rules or entitlements.';
comment on column hfcc.commerce_products.rules is 'Validated product rule configuration for eligibility, pricing, cart behavior, and app-specific commerce rules.';
comment on column hfcc.commerce_products.entitlements is 'Validated entitlement configuration. ledger_wallet_grants can define wallet grants for product purchases.';
comment on column hfcc.commerce_products.payload is 'App-specific product payload used by later operational services.';
comment on column hfcc.commerce_products.metadata is 'Operational product metadata.';
comment on column hfcc.commerce_products.is_active is 'Whether the product is visible for new commerce flows.';
comment on column hfcc.commerce_products.created_at is 'Timestamp when the product was created.';
comment on column hfcc.commerce_products.updated_at is 'Timestamp when the product was last updated.';

comment on column hfcc.commerce_orders.id is 'Primary key for a commerce order.';
comment on column hfcc.commerce_orders.user_id is 'HFCC user that owns the order.';
comment on column hfcc.commerce_orders.order_type_code is 'Validated order type code from hfcc.types, such as one-time, subscription initial, or subscription renewal.';
comment on column hfcc.commerce_orders.parent_order_id is 'Optional previous commerce order, used for renewal chains and adjustments.';
comment on column hfcc.commerce_orders.status_code is 'Validated order lifecycle status code from hfcc.types.';
comment on column hfcc.commerce_orders.payment_status_code is 'Validated order payment status code from hfcc.types.';
comment on column hfcc.commerce_orders.billing_interval_code is 'Validated billing interval for subscription initial and renewal orders. Null for one-time orders.';
comment on column hfcc.commerce_orders.subtotal_amount is 'Order subtotal before discounts, tax, and shipping.';
comment on column hfcc.commerce_orders.discount_amount is 'Total discount amount applied to the order.';
comment on column hfcc.commerce_orders.tax_amount is 'Total tax amount applied to the order.';
comment on column hfcc.commerce_orders.shipping_amount is 'Total shipping amount applied to the order.';
comment on column hfcc.commerce_orders.total_amount is 'Final order total amount.';
comment on column hfcc.commerce_orders.currency_code is 'Plain text currency code used for all order amount columns; non-ledger tables intentionally do not FK to ledger_currencies.';
comment on column hfcc.commerce_orders.billing_info is 'Validated billing information JSON for the order.';
comment on column hfcc.commerce_orders.shipping_info is 'Validated shipping information JSON for the order.';
comment on column hfcc.commerce_orders.metadata is 'Operational order metadata.';
comment on column hfcc.commerce_orders.created_at is 'Timestamp when the order was created.';
comment on column hfcc.commerce_orders.updated_at is 'Timestamp when the order was last updated.';

comment on column hfcc.commerce_order_items.id is 'Primary key for a commerce order item.';
comment on column hfcc.commerce_order_items.order_id is 'Order that owns this item.';
comment on column hfcc.commerce_order_items.product_id is 'Canonical commerce product purchased by this item. Product details are still snapshotted in JSON for history.';
comment on column hfcc.commerce_order_items.subscription_id is 'Optional subscription associated with this order item, mainly for duplicated renewal order items.';
comment on column hfcc.commerce_order_items.status_code is 'Validated order item status code from hfcc.types.';
comment on column hfcc.commerce_order_items.quantity is 'Quantity purchased.';
comment on column hfcc.commerce_order_items.unit_amount is 'Unit amount snapshot.';
comment on column hfcc.commerce_order_items.subtotal_amount is 'Item subtotal before discounts and tax.';
comment on column hfcc.commerce_order_items.discount_amount is 'Item discount amount.';
comment on column hfcc.commerce_order_items.tax_amount is 'Item tax amount.';
comment on column hfcc.commerce_order_items.total_amount is 'Final item total amount.';
comment on column hfcc.commerce_order_items.currency_code is 'Plain text currency code used for all order item amount columns; non-ledger tables intentionally do not FK to ledger_currencies.';
comment on column hfcc.commerce_order_items.rules_snapshot is 'Product rules snapshot captured at purchase time.';
comment on column hfcc.commerce_order_items.entitlements_snapshot is 'Product entitlements snapshot captured at purchase time.';
comment on column hfcc.commerce_order_items.payload_snapshot is 'Product payload/detail snapshot captured at purchase time. Product name and type are stored under payload_snapshot.product; the canonical relation is product_id.';
comment on column hfcc.commerce_order_items.metadata is 'Operational order item metadata.';
comment on column hfcc.commerce_order_items.created_at is 'Timestamp when the order item was created.';
comment on column hfcc.commerce_order_items.updated_at is 'Timestamp when the order item was last updated.';

comment on column hfcc.commerce_payment_methods.id is 'Primary key for a saved payment method reference.';
comment on column hfcc.commerce_payment_methods.user_id is 'HFCC user that owns the saved payment method.';
comment on column hfcc.commerce_payment_methods.provider_code is 'Validated payment provider code from hfcc.types.';
comment on column hfcc.commerce_payment_methods.payment_method_type_code is 'Validated payment method type code from hfcc.types.';
comment on column hfcc.commerce_payment_methods.provider_payment_method_id is 'Provider token or external payment method identifier. Raw card or bank data must not be stored.';
comment on column hfcc.commerce_payment_methods.label is 'Optional user-facing payment method label.';
comment on column hfcc.commerce_payment_methods.billing_info is 'Validated billing information JSON associated with the method.';
comment on column hfcc.commerce_payment_methods.metadata is 'Operational payment method metadata.';
comment on column hfcc.commerce_payment_methods.is_default is 'Whether this is the default payment method for the user.';
comment on column hfcc.commerce_payment_methods.created_at is 'Timestamp when the payment method reference was created.';
comment on column hfcc.commerce_payment_methods.updated_at is 'Timestamp when the payment method reference was last updated.';

comment on column hfcc.commerce_payment_intents.id is 'Primary key for a commerce payment intent.';
comment on column hfcc.commerce_payment_intents.order_id is 'Order being paid.';
comment on column hfcc.commerce_payment_intents.user_id is 'HFCC user that owns the payment attempt.';
comment on column hfcc.commerce_payment_intents.provider_code is 'Validated payment provider code from hfcc.types.';
comment on column hfcc.commerce_payment_intents.status_code is 'Validated payment intent status code from hfcc.types.';
comment on column hfcc.commerce_payment_intents.amount is 'Payment intent amount.';
comment on column hfcc.commerce_payment_intents.currency_code is 'Plain text payment intent currency; non-ledger tables intentionally do not FK to ledger_currencies.';
comment on column hfcc.commerce_payment_intents.provider_payment_intent_id is 'Provider-side payment intent identifier.';
comment on column hfcc.commerce_payment_intents.payment_method_id is 'Optional saved payment method used for this attempt.';
comment on column hfcc.commerce_payment_intents.request_payload is 'Validated provider request payload snapshot.';
comment on column hfcc.commerce_payment_intents.response_payload is 'Validated provider response payload snapshot.';
comment on column hfcc.commerce_payment_intents.metadata is 'Operational payment intent metadata.';
comment on column hfcc.commerce_payment_intents.error_message is 'Last provider or processing error message.';
comment on column hfcc.commerce_payment_intents.created_at is 'Timestamp when the payment intent was created.';
comment on column hfcc.commerce_payment_intents.updated_at is 'Timestamp when the payment intent was last updated.';

comment on column hfcc.devices.id is 'Primary key for a registered device.';
comment on column hfcc.devices.user_id is 'HFCC user that owns the device.';
comment on column hfcc.devices.platform_code is 'Validated device platform code from hfcc.types.';
comment on column hfcc.devices.push_provider_code is 'Validated push provider code from hfcc.types.';
comment on column hfcc.devices.push_token is 'Push notification token when available.';
comment on column hfcc.devices.device_name is 'Optional user or platform supplied device name.';
comment on column hfcc.devices.app_version is 'Application version last reported by the device.';
comment on column hfcc.devices.last_seen_at is 'Timestamp when the device was last observed.';
comment on column hfcc.devices.metadata is 'Operational device metadata.';
comment on column hfcc.devices.created_at is 'Timestamp when the device row was created.';
comment on column hfcc.devices.updated_at is 'Timestamp when the device row was last updated.';

comment on column hfcc.outgoing_messages.id is 'Primary key for an outgoing message request.';
comment on column hfcc.outgoing_messages.user_id is 'Optional HFCC user associated with the message.';
comment on column hfcc.outgoing_messages.channel_code is 'Validated delivery channel code from hfcc.types.';
comment on column hfcc.outgoing_messages.recipient is 'Delivery address, phone number, device token, webhook URL, or provider-specific recipient.';
comment on column hfcc.outgoing_messages.template_code is 'Optional validated message template code from hfcc.types. Template JSON can be stored in types.metadata.';
comment on column hfcc.outgoing_messages.subject is 'Optional message subject.';
comment on column hfcc.outgoing_messages.body is 'Optional message body.';
comment on column hfcc.outgoing_messages.payload is 'Structured message payload for rendering or provider delivery.';
comment on column hfcc.outgoing_messages.status_code is 'Validated message delivery status code from hfcc.types.';
comment on column hfcc.outgoing_messages.provider_code is 'Validated message provider code from hfcc.types.';
comment on column hfcc.outgoing_messages.provider_message_id is 'Provider-specific delivery identifier.';
comment on column hfcc.outgoing_messages.source_type is 'Optional source entity type that requested this message.';
comment on column hfcc.outgoing_messages.source_id is 'Optional source entity id that requested this message.';
comment on column hfcc.outgoing_messages.send_after is 'Earliest time this outgoing message should be delivered. The insert trigger copies this to events_outbox.run_after.';
comment on column hfcc.outgoing_messages.read_at is 'Timestamp when the recipient read or acknowledged the message in the app.';
comment on column hfcc.outgoing_messages.sent_at is 'Timestamp when the message was sent.';
comment on column hfcc.outgoing_messages.error_message is 'Last delivery error message.';
comment on column hfcc.outgoing_messages.metadata is 'Provider-agnostic message metadata for routing, escalation, and operational annotations.';
comment on column hfcc.outgoing_messages.created_at is 'Timestamp when the outgoing message was created.';
comment on column hfcc.outgoing_messages.updated_at is 'Timestamp when the outgoing message was last updated.';

comment on column hfcc.activity_logs.id is 'Primary key for an activity log record.';
comment on column hfcc.activity_logs.actor_user_id is 'HFCC user that performed the activity.';
comment on column hfcc.activity_logs.action_code is 'Validated activity action code from hfcc.types.';
comment on column hfcc.activity_logs.target_type is 'Optional polymorphic target entity type.';
comment on column hfcc.activity_logs.target_id is 'Optional polymorphic target entity identifier.';
comment on column hfcc.activity_logs.description is 'Optional human-readable activity description.';
comment on column hfcc.activity_logs.metadata is 'Structured activity metadata.';
comment on column hfcc.activity_logs.source_type is 'Optional source entity type that produced the activity log.';
comment on column hfcc.activity_logs.source_id is 'Optional source entity id that produced the activity log.';
comment on column hfcc.activity_logs.created_at is 'Timestamp when the activity log was created.';

comment on column hfcc.audit_logs.id is 'Primary key for an audit log record.';
comment on column hfcc.audit_logs.actor_user_id is 'HFCC user associated with the audited change when available.';
comment on column hfcc.audit_logs.action_code is 'Validated audit action code from hfcc.types.';
comment on column hfcc.audit_logs.entity is 'Table or entity name that changed.';
comment on column hfcc.audit_logs.entity_id is 'Identifier of the changed entity when available.';
comment on column hfcc.audit_logs.old_data is 'JSON snapshot of the row before update or delete.';
comment on column hfcc.audit_logs.new_data is 'JSON snapshot of the row after insert or update.';
comment on column hfcc.audit_logs.ip_address is 'Optional client IP address associated with the audited action.';
comment on column hfcc.audit_logs.user_agent is 'Optional client user agent associated with the audited action.';
comment on column hfcc.audit_logs.metadata is 'Structured audit metadata.';
comment on column hfcc.audit_logs.created_at is 'Timestamp when the audit log was created.';

comment on trigger ledger_entries_balance_check on hfcc.ledger_entries is 'Deferred constraint trigger that enforces balanced ledger entries per currency.';
comment on trigger ledger_transactions_balance_check on hfcc.ledger_transactions is 'Deferred constraint trigger that enforces ledger transactions have balanced entries.';
comment on trigger prevent_immutable_subscription_update on hfcc.subscriptions is 'Blocks unauthorized updates to immutable paid historical subscriptions.';
comment on trigger after_subscription_activation on hfcc.subscriptions is 'Schedules lifecycle jobs when an existing subscription becomes active and paid after a renewal.';
comment on trigger validate_promotion_usage on hfcc.promotion_usages is 'Checks promotion availability and usage limits before inserting usage.';
comment on trigger after_promotion_usage_insert on hfcc.promotion_usages is 'Updates promotion counters after usage insertion.';
comment on trigger enqueue_outgoing_message_outbox on hfcc.outgoing_messages is 'Creates an outbox send request after pending outgoing message insertion.';
comment on trigger audit_row_change on hfcc.users is 'Writes HFCC user row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.subscriptions is 'Writes subscription row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.ledger_wallet_grants is 'Writes wallet grant state changes to audit_logs.';
comment on trigger audit_row_change on hfcc.promotions is 'Writes promotion row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.promotion_usages is 'Writes promotion usage row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.commerce_products is 'Writes commerce product row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.commerce_orders is 'Writes commerce order row changes to audit_logs.';
comment on trigger after_commerce_order_confirmed on hfcc.commerce_orders is 'Processes commerce order items when an order is confirmed.';
comment on trigger audit_row_change on hfcc.commerce_order_items is 'Writes commerce order item row changes to audit_logs.';
comment on trigger after_commerce_order_item_status_change on hfcc.commerce_order_items is 'Updates parent commerce order status from item statuses.';
comment on trigger after_commerce_order_item_totals_change on hfcc.commerce_order_items is 'Recalculates parent commerce order totals after billable order item changes.';
comment on trigger audit_row_change on hfcc.commerce_payment_methods is 'Writes commerce payment method row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.commerce_payment_intents is 'Writes commerce payment intent row changes to audit_logs.';
comment on trigger after_commerce_payment_intent_status_change on hfcc.commerce_payment_intents is 'Recalculates parent commerce order payment status after payment intent status or amount changes.';
comment on trigger audit_row_change on hfcc.outgoing_messages is 'Writes outgoing message row changes to audit_logs.';
comment on trigger audit_row_change on hfcc.ledger_transactions is 'Writes ledger transaction row changes to audit_logs.';

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table hfcc.types enable row level security;
alter table hfcc.json_schemas enable row level security;
alter table hfcc.users enable row level security;
alter table hfcc.media enable row level security;
alter table hfcc.media_relations enable row level security;
alter table hfcc.settings enable row level security;
alter table hfcc.events_outbox enable row level security;
alter table hfcc.events_inbox enable row level security;
alter table hfcc.jobs enable row level security;
alter table hfcc.ledger_currencies enable row level security;
alter table hfcc.ledger_accounts enable row level security;
alter table hfcc.ledger_transactions enable row level security;
alter table hfcc.ledger_entries enable row level security;
alter table hfcc.ledger_wallet_grants enable row level security;
alter table hfcc.subscriptions enable row level security;
alter table hfcc.promotions enable row level security;
alter table hfcc.promotion_usages enable row level security;
alter table hfcc.commerce_products enable row level security;
alter table hfcc.commerce_orders enable row level security;
alter table hfcc.commerce_order_items enable row level security;
alter table hfcc.commerce_payment_methods enable row level security;
alter table hfcc.commerce_payment_intents enable row level security;
alter table hfcc.devices enable row level security;
alter table hfcc.outgoing_messages enable row level security;
alter table hfcc.activity_logs enable row level security;
alter table hfcc.audit_logs enable row level security;

-- Central metadata read policies.
drop policy if exists "types active rows are readable" on hfcc.types;
create policy "types active rows are readable"
on hfcc.types
for select
using (is_active or auth.role() = 'service_role');

drop policy if exists "types service role all" on hfcc.types;
create policy "types service role all"
on hfcc.types
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "JSON schemas active rows are readable" on hfcc.json_schemas;
create policy "JSON schemas active rows are readable"
on hfcc.json_schemas
for select
using (is_active or auth.role() = 'service_role');

drop policy if exists "JSON schemas service role all" on hfcc.json_schemas;
create policy "JSON schemas service role all"
on hfcc.json_schemas
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Users.
drop policy if exists "users select own" on hfcc.users;
create policy "users select own"
on hfcc.users
for select
using (id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "users update own" on hfcc.users;
create policy "users update own"
on hfcc.users
for update
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "users service role all" on hfcc.users;
create policy "users service role all"
on hfcc.users
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Devices.
drop policy if exists "devices users select own" on hfcc.devices;
create policy "devices users select own"
on hfcc.devices
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "devices users insert own" on hfcc.devices;
create policy "devices users insert own"
on hfcc.devices
for insert
with check (user_id = auth.uid());

drop policy if exists "devices users update own" on hfcc.devices;
create policy "devices users update own"
on hfcc.devices
for update
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "devices users delete own" on hfcc.devices;
create policy "devices users delete own"
on hfcc.devices
for delete
using (user_id = auth.uid());

drop policy if exists "devices service role all" on hfcc.devices;
create policy "devices service role all"
on hfcc.devices
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Event tables: direct writes are service-only.
drop policy if exists "outbox events service role all" on hfcc.events_outbox;
create policy "outbox events service role all"
on hfcc.events_outbox
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "inbox events service role all" on hfcc.events_inbox;
create policy "inbox events service role all"
on hfcc.events_inbox
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Jobs.
drop policy if exists "jobs service role all" on hfcc.jobs;
create policy "jobs service role all"
on hfcc.jobs
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Settings.
drop policy if exists "settings public select public" on hfcc.settings;
create policy "settings public select public"
on hfcc.settings
for select
using (
  is_public
  or auth.role() = 'service_role'
  or (scope_type = 'hfcc.settings.scope_type.user' and scope_id = auth.uid())
);

drop policy if exists "settings users insert own" on hfcc.settings;
create policy "settings users insert own"
on hfcc.settings
for insert
with check (scope_type = 'hfcc.settings.scope_type.user' and scope_id = auth.uid());

drop policy if exists "settings users update own" on hfcc.settings;
create policy "settings users update own"
on hfcc.settings
for update
using (scope_type = 'hfcc.settings.scope_type.user' and scope_id = auth.uid())
with check (scope_type = 'hfcc.settings.scope_type.user' and scope_id = auth.uid());

drop policy if exists "settings users delete own" on hfcc.settings;
create policy "settings users delete own"
on hfcc.settings
for delete
using (scope_type = 'hfcc.settings.scope_type.user' and scope_id = auth.uid());

drop policy if exists "settings service role all" on hfcc.settings;
create policy "settings service role all"
on hfcc.settings
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Ledger.
drop policy if exists "ledger currencies active readable" on hfcc.ledger_currencies;
create policy "ledger currencies active readable"
on hfcc.ledger_currencies
for select
using (is_active or auth.role() = 'service_role');

drop policy if exists "ledger currencies service role all" on hfcc.ledger_currencies;
create policy "ledger currencies service role all"
on hfcc.ledger_currencies
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "ledger accounts users select own" on hfcc.ledger_accounts;
create policy "ledger accounts users select own"
on hfcc.ledger_accounts
for select
using (
  auth.role() = 'service_role'
  or (owner_type = 'hfcc.ledger_accounts.owner_type.user' and owner_id = auth.uid())
);

drop policy if exists "ledger accounts service role all" on hfcc.ledger_accounts;
create policy "ledger accounts service role all"
on hfcc.ledger_accounts
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "ledger entries users select own" on hfcc.ledger_entries;
create policy "ledger entries users select own"
on hfcc.ledger_entries
for select
using (
  auth.role() = 'service_role'
  or exists (
    select 1
    from hfcc.ledger_accounts la
    where la.id = ledger_entries.account_id
      and la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = auth.uid()
  )
);

drop policy if exists "ledger entries service role all" on hfcc.ledger_entries;
create policy "ledger entries service role all"
on hfcc.ledger_entries
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "ledger transactions users select own" on hfcc.ledger_transactions;
create policy "ledger transactions users select own"
on hfcc.ledger_transactions
for select
using (
  auth.role() = 'service_role'
  or exists (
    select 1
    from hfcc.ledger_entries le
    join hfcc.ledger_accounts la on la.id = le.account_id
    where le.transaction_id = ledger_transactions.id
      and la.owner_type = 'hfcc.ledger_accounts.owner_type.user'
      and la.owner_id = auth.uid()
  )
);

drop policy if exists "ledger transactions service role all" on hfcc.ledger_transactions;
create policy "ledger transactions service role all"
on hfcc.ledger_transactions
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Subscription and loyalty.
drop policy if exists "subscriptions users select own" on hfcc.subscriptions;
create policy "subscriptions users select own"
on hfcc.subscriptions
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "subscriptions service role all" on hfcc.subscriptions;
create policy "subscriptions service role all"
on hfcc.subscriptions
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "ledger wallet grants users select own" on hfcc.ledger_wallet_grants;
create policy "ledger wallet grants users select own"
on hfcc.ledger_wallet_grants
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "ledger wallet grants service role all" on hfcc.ledger_wallet_grants;
create policy "ledger wallet grants service role all"
on hfcc.ledger_wallet_grants
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "promotions active readable" on hfcc.promotions;
create policy "promotions active readable"
on hfcc.promotions
for select
using (
  auth.role() = 'service_role'
  or (
    is_active
    and (starts_at is null or starts_at <= now())
    and (expires_at is null or expires_at > now())
  )
);

drop policy if exists "promotions service role all" on hfcc.promotions;
create policy "promotions service role all"
on hfcc.promotions
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "promotion usages users select own" on hfcc.promotion_usages;
create policy "promotion usages users select own"
on hfcc.promotion_usages
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "promotion usages service role all" on hfcc.promotion_usages;
create policy "promotion usages service role all"
on hfcc.promotion_usages
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Commerce.
drop policy if exists "commerce products active readable" on hfcc.commerce_products;
create policy "commerce products active readable"
on hfcc.commerce_products
for select
using (
  auth.role() = 'service_role'
  or (
    is_active
    and status_code = 'hfcc.commerce_products.status_code.active'
  )
);

drop policy if exists "commerce products service role all" on hfcc.commerce_products;
create policy "commerce products service role all"
on hfcc.commerce_products
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "commerce orders users select own" on hfcc.commerce_orders;
create policy "commerce orders users select own"
on hfcc.commerce_orders
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "commerce orders service role all" on hfcc.commerce_orders;
create policy "commerce orders service role all"
on hfcc.commerce_orders
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "commerce order items users select own" on hfcc.commerce_order_items;
create policy "commerce order items users select own"
on hfcc.commerce_order_items
for select
using (
  auth.role() = 'service_role'
  or exists (
    select 1
    from hfcc.commerce_orders o
    where o.id = commerce_order_items.order_id
      and o.user_id = auth.uid()
  )
);

drop policy if exists "commerce order items service role all" on hfcc.commerce_order_items;
create policy "commerce order items service role all"
on hfcc.commerce_order_items
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "commerce payment methods users select own" on hfcc.commerce_payment_methods;
create policy "commerce payment methods users select own"
on hfcc.commerce_payment_methods
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "commerce payment methods users insert own" on hfcc.commerce_payment_methods;
create policy "commerce payment methods users insert own"
on hfcc.commerce_payment_methods
for insert
with check (user_id = auth.uid());

drop policy if exists "commerce payment methods users update own" on hfcc.commerce_payment_methods;
create policy "commerce payment methods users update own"
on hfcc.commerce_payment_methods
for update
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "commerce payment methods users delete own" on hfcc.commerce_payment_methods;
create policy "commerce payment methods users delete own"
on hfcc.commerce_payment_methods
for delete
using (user_id = auth.uid());

drop policy if exists "commerce payment methods service role all" on hfcc.commerce_payment_methods;
create policy "commerce payment methods service role all"
on hfcc.commerce_payment_methods
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "commerce payment intents users select own" on hfcc.commerce_payment_intents;
create policy "commerce payment intents users select own"
on hfcc.commerce_payment_intents
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "commerce payment intents service role all" on hfcc.commerce_payment_intents;
create policy "commerce payment intents service role all"
on hfcc.commerce_payment_intents
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Media.
drop policy if exists "media owners select own" on hfcc.media;
create policy "media owners select own"
on hfcc.media
for select
using (
  auth.role() = 'service_role'
  or (owner_type = 'hfcc.media.owner_type.user' and owner_id = auth.uid())
);

drop policy if exists "media service role all" on hfcc.media;
create policy "media service role all"
on hfcc.media
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "media relations owners select own" on hfcc.media_relations;
create policy "media relations owners select own"
on hfcc.media_relations
for select
using (
  auth.role() = 'service_role'
  or exists (
    select 1
    from hfcc.media m
    where m.id = media_relations.media_id
      and m.owner_type = 'hfcc.media.owner_type.user'
      and m.owner_id = auth.uid()
  )
  or (entity = 'users' and entity_id = auth.uid())
);

drop policy if exists "media relations service role all" on hfcc.media_relations;
create policy "media relations service role all"
on hfcc.media_relations
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- Messages and logs.
drop policy if exists "outgoing messages users select own" on hfcc.outgoing_messages;
create policy "outgoing messages users select own"
on hfcc.outgoing_messages
for select
using (user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "outgoing messages service role all" on hfcc.outgoing_messages;
create policy "outgoing messages service role all"
on hfcc.outgoing_messages
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "activity logs users select own" on hfcc.activity_logs;
create policy "activity logs users select own"
on hfcc.activity_logs
for select
using (actor_user_id = auth.uid() or auth.role() = 'service_role');

drop policy if exists "activity logs service role all" on hfcc.activity_logs;
create policy "activity logs service role all"
on hfcc.activity_logs
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

drop policy if exists "audit logs service role all" on hfcc.audit_logs;
create policy "audit logs service role all"
on hfcc.audit_logs
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

-- ---------------------------------------------------------------------------
-- API grants. RLS remains the authorization boundary.
-- ---------------------------------------------------------------------------

grant usage on schema hfcc to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

grant select on hfcc.types to anon, authenticated;
grant select on hfcc.json_schemas to anon, authenticated;
grant select on hfcc.ledger_currencies to anon, authenticated;
grant select on hfcc.promotions to anon, authenticated;
grant select on hfcc.commerce_products to anon, authenticated;
grant select on hfcc.settings to anon, authenticated;

grant select, update on hfcc.users to authenticated;
grant select, insert, update, delete on hfcc.devices to authenticated;
grant select, insert, update, delete on hfcc.settings to authenticated;
grant select on hfcc.ledger_accounts to authenticated;
grant select on hfcc.ledger_entries to authenticated;
grant select on hfcc.ledger_transactions to authenticated;
grant select on hfcc.ledger_balances to authenticated;
grant select on hfcc.subscriptions to authenticated;
grant select on hfcc.ledger_wallet_grants to authenticated;
grant select on hfcc.promotion_usages to authenticated;
grant select on hfcc.commerce_orders to authenticated;
grant select on hfcc.commerce_order_items to authenticated;
grant select, insert, update, delete on hfcc.commerce_payment_methods to authenticated;
grant select on hfcc.commerce_payment_intents to authenticated;
grant select on hfcc.media to authenticated;
grant select on hfcc.media_relations to authenticated;
grant select on hfcc.outgoing_messages to authenticated;
grant select on hfcc.activity_logs to authenticated;

grant all on table hfcc.types to service_role;
grant all on table hfcc.json_schemas to service_role;
grant all on table hfcc.users to service_role;
grant all on table hfcc.media to service_role;
grant all on table hfcc.media_relations to service_role;
grant all on table hfcc.settings to service_role;
grant all on table hfcc.events_outbox to service_role;
grant all on table hfcc.events_inbox to service_role;
grant all on table hfcc.jobs to service_role;
grant all on table hfcc.ledger_currencies to service_role;
grant all on table hfcc.ledger_accounts to service_role;
grant all on table hfcc.ledger_transactions to service_role;
grant all on table hfcc.ledger_entries to service_role;
grant all on table hfcc.ledger_wallet_grants to service_role;
grant all on table hfcc.subscriptions to service_role;
grant all on table hfcc.promotions to service_role;
grant all on table hfcc.promotion_usages to service_role;
grant all on table hfcc.commerce_products to service_role;
grant all on table hfcc.commerce_orders to service_role;
grant all on table hfcc.commerce_order_items to service_role;
grant all on table hfcc.commerce_payment_methods to service_role;
grant all on table hfcc.commerce_payment_intents to service_role;
grant all on table hfcc.devices to service_role;
grant all on table hfcc.outgoing_messages to service_role;
grant all on table hfcc.activity_logs to service_role;
grant all on table hfcc.audit_logs to service_role;
grant select on hfcc.ledger_balances to service_role;

grant execute on function hfcc.is_valid_type(text, text, text) to anon, authenticated, service_role;
grant execute on function hfcc.is_valid_type(text, text, text, text) to anon, authenticated, service_role;

revoke all on function hfcc.enqueue_outbox_event(text, text, uuid, jsonb, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.claim_due_jobs(integer) from public, anon, authenticated;
revoke all on function hfcc.handle_job_subscription_maintenance_daily(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_job_subscription_expire(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_job_subscription_activate(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_job_subscription_renewal_notice(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_outgoing_message_send_requested(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_outgoing_message_escalation_due(jsonb) from public, anon, authenticated;
revoke all on function hfcc.handle_subscription_renewal_notice_requested(jsonb) from public, anon, authenticated;
revoke all on function hfcc.process_due_jobs(integer) from public, anon, authenticated;
revoke all on function hfcc.claim_due_events_outbox(integer) from public, anon, authenticated;
revoke all on function hfcc.process_due_events_outbox(integer) from public, anon, authenticated;
revoke all on function hfcc.retry_stuck_jobs(interval) from public, anon, authenticated;
revoke all on function hfcc.retry_stuck_events_outbox(interval) from public, anon, authenticated;
revoke all on function hfcc.handle_new_auth_user() from public, anon, authenticated;
revoke all on function hfcc.ensure_hfcc_user(uuid) from public, anon, authenticated;
revoke all on function hfcc.ensure_user_ledger_accounts(uuid) from public, anon, authenticated;
revoke all on function hfcc.assert_ledger_transaction_balanced(uuid) from public, anon, authenticated;
revoke all on function hfcc.assert_non_system_balances_allowed(uuid) from public, anon, authenticated;
revoke all on function hfcc.validate_ledger_entries_balance_trigger() from public, anon, authenticated;
revoke all on function hfcc.validate_ledger_transaction_balance_trigger() from public, anon, authenticated;
revoke all on function hfcc.create_ledger_transaction(text, uuid, jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function hfcc.spend_user_balance(uuid, text, numeric, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function hfcc.subscription_interval(text) from public, anon, authenticated;
revoke all on function hfcc.prevent_immutable_subscription_update() from public, anon, authenticated;
revoke all on function hfcc.schedule_subscription_lifecycle_jobs(uuid, boolean) from public, anon, authenticated;
revoke all on function hfcc.activate_scheduled_subscription(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.enqueue_subscription_renewal_notice(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.create_subscription_from_order(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.create_subscription_renewal_order(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.apply_subscription_renewal_order(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.apply_subscription_entitlements(uuid, uuid, timestamptz, boolean) from public, anon, authenticated;
revoke all on function hfcc.after_subscription_activation() from public, anon, authenticated;
revoke all on function hfcc.process_subscription_maintenance(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.validate_promotion_for_user(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function hfcc.apply_promotion(uuid, text, text, uuid, text, uuid, uuid) from public, anon, authenticated;
revoke all on function hfcc.validate_promotion_usage() from public, anon, authenticated;
revoke all on function hfcc.after_promotion_usage_insert() from public, anon, authenticated;
revoke all on function hfcc.apply_commerce_order_item_entitlements(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.recalculate_commerce_order_totals(uuid) from public, anon, authenticated;
revoke all on function hfcc.recalculate_commerce_order_payment_status(uuid) from public, anon, authenticated;
revoke all on function hfcc.recalculate_commerce_order_status_from_items(uuid) from public, anon, authenticated;
revoke all on function hfcc.process_commerce_order(uuid, timestamptz) from public, anon, authenticated;
revoke all on function hfcc.after_commerce_order_confirmed() from public, anon, authenticated;
revoke all on function hfcc.after_commerce_order_item_status_change() from public, anon, authenticated;
revoke all on function hfcc.after_commerce_order_item_totals_change() from public, anon, authenticated;
revoke all on function hfcc.after_commerce_payment_intent_status_change() from public, anon, authenticated;
revoke all on function hfcc.enqueue_outgoing_message_outbox() from public, anon, authenticated;
revoke all on function hfcc.resolve_outgoing_message_recipient(uuid, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function hfcc.enqueue_message_escalation(uuid, integer) from public, anon, authenticated;
revoke all on function hfcc.audit_row_change() from public, anon, authenticated;
revoke all on function hfcc.install_audit_trigger(regclass) from public, anon, authenticated;

grant execute on function hfcc.enqueue_outbox_event(text, text, uuid, jsonb, jsonb, timestamptz) to service_role;
grant execute on function hfcc.claim_due_jobs(integer) to service_role;
grant execute on function hfcc.handle_job_subscription_maintenance_daily(jsonb) to service_role;
grant execute on function hfcc.handle_job_subscription_expire(jsonb) to service_role;
grant execute on function hfcc.handle_job_subscription_activate(jsonb) to service_role;
grant execute on function hfcc.handle_job_subscription_renewal_notice(jsonb) to service_role;
grant execute on function hfcc.handle_outgoing_message_send_requested(jsonb) to service_role;
grant execute on function hfcc.handle_outgoing_message_escalation_due(jsonb) to service_role;
grant execute on function hfcc.handle_subscription_renewal_notice_requested(jsonb) to service_role;
grant execute on function hfcc.process_due_jobs(integer) to service_role;
grant execute on function hfcc.claim_due_events_outbox(integer) to service_role;
grant execute on function hfcc.process_due_events_outbox(integer) to service_role;
grant execute on function hfcc.retry_stuck_jobs(interval) to service_role;
grant execute on function hfcc.retry_stuck_events_outbox(interval) to service_role;
grant execute on function hfcc.handle_new_auth_user() to service_role;
grant execute on function hfcc.ensure_hfcc_user(uuid) to service_role;
grant execute on function hfcc.ensure_user_ledger_accounts(uuid) to service_role;
grant execute on function hfcc.assert_ledger_transaction_balanced(uuid) to service_role;
grant execute on function hfcc.assert_non_system_balances_allowed(uuid) to service_role;
grant execute on function hfcc.validate_ledger_entries_balance_trigger() to service_role;
grant execute on function hfcc.validate_ledger_transaction_balance_trigger() to service_role;
grant execute on function hfcc.create_ledger_transaction(text, uuid, jsonb, text, jsonb) to service_role;
grant execute on function hfcc.spend_user_balance(uuid, text, numeric, uuid, uuid, text, jsonb) to service_role;
grant execute on function hfcc.subscription_interval(text) to service_role;
grant execute on function hfcc.prevent_immutable_subscription_update() to service_role;
grant execute on function hfcc.schedule_subscription_lifecycle_jobs(uuid, boolean) to service_role;
grant execute on function hfcc.activate_scheduled_subscription(uuid, timestamptz) to service_role;
grant execute on function hfcc.enqueue_subscription_renewal_notice(uuid, timestamptz) to service_role;
grant execute on function hfcc.create_subscription_from_order(uuid, timestamptz) to service_role;
grant execute on function hfcc.create_subscription_renewal_order(uuid, timestamptz) to service_role;
grant execute on function hfcc.apply_subscription_renewal_order(uuid, uuid, timestamptz) to service_role;
grant execute on function hfcc.apply_subscription_entitlements(uuid, uuid, timestamptz, boolean) to service_role;
grant execute on function hfcc.after_subscription_activation() to service_role;
grant execute on function hfcc.process_subscription_maintenance(uuid, timestamptz) to service_role;
grant execute on function hfcc.validate_promotion_for_user(uuid, text, text, uuid, uuid) to authenticated, service_role;
grant execute on function hfcc.apply_promotion(uuid, text, text, uuid, text, uuid, uuid) to service_role;
grant execute on function hfcc.validate_promotion_usage() to service_role;
grant execute on function hfcc.after_promotion_usage_insert() to service_role;
grant execute on function hfcc.apply_commerce_order_item_entitlements(uuid, uuid, timestamptz) to service_role;
grant execute on function hfcc.recalculate_commerce_order_totals(uuid) to service_role;
grant execute on function hfcc.recalculate_commerce_order_payment_status(uuid) to service_role;
grant execute on function hfcc.recalculate_commerce_order_status_from_items(uuid) to service_role;
grant execute on function hfcc.process_commerce_order(uuid, timestamptz) to service_role;
grant execute on function hfcc.after_commerce_order_confirmed() to service_role;
grant execute on function hfcc.after_commerce_order_item_status_change() to service_role;
grant execute on function hfcc.after_commerce_order_item_totals_change() to service_role;
grant execute on function hfcc.after_commerce_payment_intent_status_change() to service_role;
grant execute on function hfcc.enqueue_outgoing_message_outbox() to service_role;
grant execute on function hfcc.resolve_outgoing_message_recipient(uuid, text, text, jsonb, jsonb) to service_role;
grant execute on function hfcc.enqueue_message_escalation(uuid, integer) to service_role;
grant execute on function hfcc.audit_row_change() to service_role;
grant execute on function hfcc.install_audit_trigger(regclass) to service_role;

-- ---------------------------------------------------------------------------
-- Unified write validation trigger
-- ---------------------------------------------------------------------------
-- This centralizes updated_at maintenance and JSON validation. Type-code
-- integrity is enforced with normal foreign keys and scope CHECK constraints.
-- It also supports future versioned tables: if a table has a version column,
-- UPDATE is converted into INSERT of a new versioned row.

create or replace function hfcc.invoke_type_handler(
  p_entity text,
  p_field text,
  p_code text,
  p_operation text,
  p_table_schema text,
  p_table_name text,
  p_row_id uuid,
  p_old_row jsonb,
  p_new_row jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_type hfcc.types%rowtype;
  v_invoke record;
  v_function_name text;
  v_payload_key text;
  v_handler_payload jsonb;
  v_payload_container jsonb;
  v_context jsonb;
  v_result_payload jsonb;
  v_results jsonb := '[]'::jsonb;
  v_started_at timestamptz;
  v_finished_at timestamptz;
  v_success boolean;
  v_all_success boolean := true;
  v_error_code text;
  v_error_message text;
  v_attempted_count integer := 0;
  v_invoked_count integer := 0;
  v_actor_text text;
  v_actor_user_id uuid;
  v_log_metadata jsonb;
begin
  select *
  into v_type
  from hfcc.types
  where code = p_code
    and schema = split_part(p_code, '.', 1)
    and entity = p_entity
    and field = p_field
    and is_active;

  if not found then
    return jsonb_build_object('dispatched', false, 'ok', true, 'reason_code', 'type_not_found_or_inactive');
  end if;

  v_context := jsonb_build_object(
    'operation', p_operation,
    'table_schema', p_table_schema,
    'table', p_table_name,
    'row_id', p_row_id,
    'type_schema', v_type.schema,
    'type_entity', p_entity,
    'type_field', p_field,
    'type_code', p_code,
    'old_row', coalesce(p_old_row, 'null'::jsonb),
    'new_row', coalesce(p_new_row, 'null'::jsonb)
  );

  for v_invoke in
    select value as config, ordinality
    from jsonb_array_elements(v_type.invoke_functions) with ordinality
  loop
    v_function_name := case
      when jsonb_typeof(v_invoke.config) = 'string' then v_invoke.config #>> '{}'
      when jsonb_typeof(v_invoke.config) = 'object' then coalesce(
        v_invoke.config ->> 'function_name',
        v_invoke.config ->> 'function',
        v_invoke.config ->> 'name'
      )
      else null
    end;
    v_payload_key := case
      when jsonb_typeof(v_invoke.config) = 'object'
        then coalesce(v_invoke.config ->> 'payload_key', v_function_name)
      else v_function_name
    end;
    v_payload_container := coalesce(p_new_row -> 'payload', '{}'::jsonb);
    v_handler_payload := '{}'::jsonb;
    v_result_payload := '{}'::jsonb;
    v_error_code := null;
    v_error_message := null;
    v_started_at := now();
    v_finished_at := null;
    v_success := false;
    v_attempted_count := v_attempted_count + 1;

    begin
      if nullif(v_function_name, '') is null then
        raise exception 'invoke_functions[%] requires function_name', v_invoke.ordinality
          using errcode = '22023';
      end if;

      if v_function_name !~ '^handle_[a-z0-9_]+$' then
        raise exception 'Invalid invoke function name: %', v_function_name
          using errcode = '22023';
      end if;

      if jsonb_typeof(v_payload_container) = 'object'
         and v_payload_key is not null
         and v_payload_container ? v_payload_key
         and jsonb_typeof(v_payload_container -> v_payload_key) = 'object' then
        v_handler_payload := v_payload_container -> v_payload_key;
      elsif jsonb_typeof(v_invoke.config) = 'object'
            and jsonb_typeof(v_invoke.config -> 'payload') = 'object' then
        v_handler_payload := v_invoke.config -> 'payload';
      end if;

      v_handler_payload := coalesce(v_handler_payload, '{}'::jsonb)
        || jsonb_build_object('_context', v_context);

      if not exists (
        select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'hfcc'
          and p.proname = v_function_name
          and p.prokind = 'f'
          and p.pronargs = 1
          and oidvectortypes(p.proargtypes) = 'jsonb'
          and p.prorettype = 'jsonb'::regtype
      ) then
        raise exception 'Configured invoke function hfcc.%(jsonb) returns jsonb does not exist', v_function_name
          using errcode = '42883';
      end if;

      execute format('select hfcc.%I($1)', v_function_name)
      using v_handler_payload
      into v_result_payload;

      v_success := true;
      v_invoked_count := v_invoked_count + 1;
      v_finished_at := now();
    exception
      when others then
        v_success := false;
        v_all_success := false;
        v_error_code := sqlstate;
        v_error_message := sqlerrm;
        v_finished_at := now();
    end;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'ordinality', v_invoke.ordinality,
      'function_name', v_function_name,
      'payload_key', v_payload_key,
      'handler_payload', coalesce(v_handler_payload, '{}'::jsonb),
      'result_payload', coalesce(v_result_payload, '{}'::jsonb),
      'success', v_success,
      'error_code', v_error_code,
      'error_message', v_error_message,
      'started_at', v_started_at,
      'finished_at', v_finished_at
    ));
  end loop;

  v_log_metadata := jsonb_build_object(
    'operation', p_operation,
    'table_schema', p_table_schema,
    'table', p_table_name,
    'type_schema', v_type.schema,
    'type_entity', p_entity,
    'type_field', p_field,
    'type_code', p_code,
    'invoke_functions', v_type.invoke_functions,
    'invoke_results', v_results,
    'attempted_count', v_attempted_count,
    'invoked_count', v_invoked_count,
    'success', v_all_success,
    'context', v_context
  );

  if v_type.log_audit then
    insert into hfcc.audit_logs (
      action_code,
      entity,
      entity_id,
      old_data,
      new_data,
      metadata
    )
    values (
      'hfcc.audit_logs.action_code.type_dispatch',
      p_table_name,
      p_row_id,
      p_old_row,
      p_new_row,
      v_log_metadata
    );
  end if;

  if v_type.log_activity then
    v_actor_text := coalesce(
      p_new_row ->> 'actor_user_id',
      p_new_row ->> 'user_id',
      p_old_row ->> 'actor_user_id',
      p_old_row ->> 'user_id'
    );

    if v_actor_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_actor_user_id := v_actor_text::uuid;
    end if;

    insert into hfcc.activity_logs (
      actor_user_id,
      action_code,
      target_type,
      target_id,
      description,
      metadata,
      source_type,
      source_id
    )
    values (
      v_actor_user_id,
      'hfcc.activity_logs.action_code.type_applied',
      p_table_schema || '.' || p_table_name,
      p_row_id,
      'Type code applied: ' || p_code,
      v_log_metadata,
      'hfcc.activity_logs.source_type.type_dispatch',
      p_row_id
    );
  end if;

  return jsonb_build_object(
    'dispatched', jsonb_array_length(v_type.invoke_functions) > 0,
    'ok', v_all_success,
    'attempted_count', v_attempted_count,
    'invoked_count', v_invoked_count,
    'logged_audit', v_type.log_audit,
    'logged_activity', v_type.log_activity,
    'results', v_results,
    'error_code', (
      select r ->> 'error_code'
      from jsonb_array_elements(v_results) r
      where r ->> 'error_code' is not null
      limit 1
    ),
    'error_message', (
      select r ->> 'error_message'
      from jsonb_array_elements(v_results) r
      where r ->> 'error_message' is not null
      limit 1
    ),
    'reason_code', case when jsonb_array_length(v_type.invoke_functions) = 0 then 'no_invoke_functions' else null end
  );
end;
$$;

create or replace function hfcc.core_after_type_dispatch()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_new_row jsonb := to_jsonb(new);
  v_old_row jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  v_row_id uuid;
  v_id_text text;
  v_field record;
  v_type record;
  v_result jsonb;
  v_ok boolean;
  v_dispatched boolean;
  v_error_message text;
begin
  if tg_when <> 'AFTER' or tg_level <> 'ROW' or tg_op not in ('INSERT', 'UPDATE') then
    return new;
  end if;

  if tg_table_name = 'audit_logs' then
    return new;
  end if;

  v_id_text := v_new_row ->> 'id';
  if v_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_row_id := v_id_text::uuid;
  end if;

  if tg_table_name = 'jobs' then
    if new.status_code = 'hfcc.jobs.status_code.processing'
       and (tg_op = 'INSERT' or (v_old_row ->> 'status_code') is distinct from new.status_code) then
      v_result := hfcc.invoke_type_handler(
        'jobs', 'job_code', new.job_code, tg_op, tg_table_schema, tg_table_name, v_row_id, v_old_row, v_new_row
      );
      v_ok := coalesce((v_result ->> 'ok')::boolean, false);
      v_dispatched := coalesce((v_result ->> 'dispatched')::boolean, false);
      v_error_message := coalesce(v_result ->> 'error_message', v_result ->> 'reason_code');

      update hfcc.jobs
      set status_code = case
            when v_ok and v_dispatched then 'hfcc.jobs.status_code.done'
            when new.attempt_count >= new.max_attempts then 'hfcc.jobs.status_code.failed'
            else 'hfcc.jobs.status_code.pending'
          end,
          processed_at = case when v_ok and v_dispatched then now() else processed_at end,
          locked_at = null,
          error_message = case when v_ok and v_dispatched then null else v_error_message end,
          updated_at = now()
      where id = new.id;
    end if;

    return new;
  end if;

  if tg_table_name = 'events_outbox' then
    if new.status_code = 'hfcc.events_outbox.status_code.processing'
       and (tg_op = 'INSERT' or (v_old_row ->> 'status_code') is distinct from new.status_code) then
      v_result := hfcc.invoke_type_handler(
        'events_outbox', 'event_code', new.event_code, tg_op, tg_table_schema, tg_table_name, v_row_id, v_old_row, v_new_row
      );
      v_ok := coalesce((v_result ->> 'ok')::boolean, false);
      v_dispatched := coalesce((v_result ->> 'dispatched')::boolean, false);
      v_error_message := coalesce(v_result ->> 'error_message', v_result ->> 'reason_code');

      update hfcc.events_outbox
      set status_code = case
            when v_ok and v_dispatched then 'hfcc.events_outbox.status_code.done'
            when new.attempt_count >= new.max_attempts then 'hfcc.events_outbox.status_code.failed'
            else 'hfcc.events_outbox.status_code.pending'
          end,
          processed_at = case when v_ok and v_dispatched then now() else processed_at end,
          locked_at = null,
          error_message = case when v_ok and v_dispatched then null else v_error_message end,
          updated_at = now()
      where id = new.id;
    end if;

    return new;
  end if;

  if tg_table_name = 'events_inbox' then
    if tg_op = 'INSERT'
       or (
         new.status_code = 'hfcc.events_inbox.status_code.processing'
         and (v_old_row ->> 'status_code') is distinct from new.status_code
       ) then
      v_result := hfcc.invoke_type_handler(
        'events_inbox', 'event_code', new.event_code, tg_op, tg_table_schema, tg_table_name, v_row_id, v_old_row, v_new_row
      );
      v_ok := coalesce((v_result ->> 'ok')::boolean, false);
      v_dispatched := coalesce((v_result ->> 'dispatched')::boolean, false);

      if v_dispatched then
        update hfcc.events_inbox
        set status_code = case when v_ok then 'hfcc.events_inbox.status_code.done' else 'hfcc.events_inbox.status_code.failed' end,
            processed_at = case when v_ok then now() else processed_at end,
            error_message = case when v_ok then null else v_result ->> 'error_message' end,
            updated_at = now()
        where id = new.id;
      end if;
    end if;

    return new;
  end if;

  for v_field in
    select key as field_name, value as code
    from jsonb_each_text(v_new_row)
  loop
    if tg_op = 'UPDATE' and (v_old_row ->> v_field.field_name) is not distinct from v_field.code then
      continue;
    end if;

    select t.entity, t.field
    into v_type
    from hfcc.types t
    where t.code = v_field.code
      and t.schema = split_part(v_field.code, '.', 1)
      and t.field = v_field.field_name
      and t.is_active
      and (
        jsonb_array_length(t.invoke_functions) > 0
        or t.log_audit
        or t.log_activity
      )
    limit 1;

    if found then
      perform hfcc.invoke_type_handler(
        v_type.entity,
        v_type.field,
        v_field.code,
        tg_op,
        tg_table_schema,
        tg_table_name,
        v_row_id,
        v_old_row,
        v_new_row
      );
    end if;
  end loop;

  return new;
end;
$$;

comment on function hfcc.invoke_type_handler(text, text, text, text, text, text, uuid, jsonb, jsonb) is
  'Generic trusted type-code invoker. Resolves ordered HFCC functions from hfcc.types.invoke_functions, passes configured payload plus _context, executes HFCC handlers, and writes audit/activity logs when requested by the type row.';

comment on function hfcc.core_after_type_dispatch() is
  'Generic AFTER INSERT/UPDATE dispatcher for type-code driven workflows, including job processing and inbox/outbox event handling.';

create or replace function hfcc.core_before_write()
returns trigger
language plpgsql
security definer
set search_path = hfcc
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_old_row jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  v_errors jsonb := '[]'::jsonb;
  v_schema record;
  v_required_key text;
  v_property record;
  v_value jsonb;
  v_expected_type text;
  v_actual_type text;
  v_entity_id uuid;
  v_next_version integer;
  v_order_user_id uuid;
  v_order_currency_code text;
  v_method_user_id uuid;
begin
  -- Maintain updated_at when the table has that column.
  if v_row ? 'updated_at' then
    v_row := jsonb_set(v_row, '{updated_at}', to_jsonb(now()), true);
    new := jsonb_populate_record(new, v_row);
  end if;

  -- Validate JSON/JSONB fields that have an active json_schemas row. The latest
  -- active schema per table field is used.
  for v_schema in
    select distinct on (js.field)
      js.field,
      js.json_schema
    from hfcc.json_schemas js
    where js.entity = tg_table_name
      and js.is_active
      and v_row ? js.field
    order by js.field, js.version desc
  loop
    v_value := v_row -> v_schema.field;

    if v_value is null or v_value = 'null'::jsonb then
      continue;
    end if;

    if v_schema.json_schema ? 'type' then
      v_expected_type := v_schema.json_schema ->> 'type';
      v_actual_type := jsonb_typeof(v_value);

      if v_expected_type = 'integer' then
        if v_actual_type <> 'number' then
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'kind', 'json_schema',
            'field', v_schema.field,
            'message', 'JSON value must be integer'
          ));
        elsif ((v_value #>> '{}')::numeric % 1 <> 0) then
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'kind', 'json_schema',
            'field', v_schema.field,
            'message', 'JSON value must be integer'
          ));
        end if;
      elsif v_expected_type in ('number.boolean.string', 'number', 'boolean', 'object', 'array')
            and v_actual_type <> v_expected_type then
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'kind', 'json_schema',
          'field', v_schema.field,
          'expected_type', v_expected_type,
          'actual_type', v_actual_type,
          'message', 'JSON value has the wrong root type'
        ));
      end if;
    end if;

    if (v_schema.json_schema ? 'required' or v_schema.json_schema ? 'properties')
       and jsonb_typeof(v_value) <> 'object' then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'kind', 'json_schema',
        'field', v_schema.field,
        'message', 'JSON value must be an object when required/properties rules are configured'
      ));
      continue;
    end if;

    if v_schema.json_schema ? 'required' then
      for v_required_key in
        select jsonb_array_elements_text(v_schema.json_schema -> 'required')
      loop
        if not (v_value ? v_required_key) then
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'kind', 'json_schema',
            'field', v_schema.field,
            'property', v_required_key,
            'message', 'Required JSON property is missing'
          ));
        end if;
      end loop;
    end if;

    if v_schema.json_schema ? 'properties' and jsonb_typeof(v_value) = 'object' then
      for v_property in
        select key, value
        from jsonb_each(v_schema.json_schema -> 'properties')
      loop
        if v_value ? v_property.key and v_property.value ? 'type' then
          v_expected_type := v_property.value ->> 'type';
          v_actual_type := jsonb_typeof(v_value -> v_property.key);

          if v_expected_type = 'integer' then
            if v_actual_type <> 'number' then
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'kind', 'json_schema',
                'field', v_schema.field,
                'property', v_property.key,
                'message', 'JSON property must be integer'
              ));
            elsif ((v_value ->> v_property.key)::numeric % 1 <> 0) then
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'kind', 'json_schema',
                'field', v_schema.field,
                'property', v_property.key,
                'message', 'JSON property must be integer'
              ));
            end if;
          elsif v_expected_type in ('number.boolean.string', 'number', 'boolean', 'object', 'array')
                and v_actual_type <> v_expected_type then
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'kind', 'json_schema',
              'field', v_schema.field,
              'property', v_property.key,
              'expected_type', v_expected_type,
              'actual_type', v_actual_type,
              'message', 'JSON property has the wrong type'
            ));
          end if;
        end if;
      end loop;
    end if;
  end loop;

  -- User roles are authorization-sensitive. Users may update their own
  -- HFCC user data, but only service role can change role_code.
  if tg_table_name = 'users'
     and tg_op = 'UPDATE'
     and auth.role() <> 'service_role'
     and v_old_row ? 'role_code'
     and v_row ? 'role_code'
     and v_old_row ->> 'role_code' is distinct from v_row ->> 'role_code' then
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'kind', 'authorization',
      'field', 'role_code',
      'message', 'Only service role can update user role_code'
    ));
  end if;

  -- User avatar ownership is a core cross-table invariant.
  if tg_table_name = 'users'
     and v_row ? 'avatar_media_id'
     and v_row ->> 'avatar_media_id' is not null
     and auth.role() <> 'service_role'
     and not exists (
       select 1
       from hfcc.media m
       where m.id = (v_row ->> 'avatar_media_id')::uuid
         and m.owner_type = 'hfcc.media.owner_type.user'
         and m.owner_id = (v_row ->> 'id')::uuid
     ) then
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'kind', 'ownership',
      'field', 'avatar_media_id',
      'message', 'User avatar media must be owned by the same user'
    ));
  end if;

  -- Commerce order item snapshots must stay attached to an order with the
  -- same currency so downstream totals and grants are coherent.
  if tg_table_name = 'subscriptions' then
    if v_row ? 'payment_method_id' and v_row ->> 'payment_method_id' is not null then
      select pm.user_id
      into v_method_user_id
      from hfcc.commerce_payment_methods pm
      where pm.id = (v_row ->> 'payment_method_id')::uuid;

      if v_method_user_id is not null
         and v_row ? 'user_id'
         and v_method_user_id is distinct from (v_row ->> 'user_id')::uuid then
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'kind', 'commerce',
          'field', 'payment_method_id',
          'message', 'Subscription payment method must belong to the subscription user'
        ));
      end if;
    end if;
  end if;

  if tg_table_name = 'commerce_order_items' then
    select o.currency_code
    into v_order_currency_code
    from hfcc.commerce_orders o
    where o.id = (v_row ->> 'order_id')::uuid;

    if v_order_currency_code is not null
       and v_row ? 'currency_code'
       and v_row ->> 'currency_code' is distinct from v_order_currency_code then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'kind', 'commerce',
        'field', 'currency_code',
        'message', 'Commerce order item currency must match the order currency'
      ));
    end if;
  end if;

  -- Payment attempts must belong to the same user and currency as their order,
  -- and any saved payment method must belong to the same user.
  if tg_table_name = 'commerce_payment_intents' then
    select o.user_id, o.currency_code
    into v_order_user_id, v_order_currency_code
    from hfcc.commerce_orders o
    where o.id = (v_row ->> 'order_id')::uuid;

    if v_order_user_id is not null
       and v_row ? 'user_id'
       and (v_row ->> 'user_id')::uuid is distinct from v_order_user_id then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'kind', 'commerce',
        'field', 'user_id',
        'message', 'Commerce payment intent user must match the order user'
      ));
    end if;

    if v_order_currency_code is not null
       and v_row ? 'currency_code'
       and v_row ->> 'currency_code' is distinct from v_order_currency_code then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'kind', 'commerce',
        'field', 'currency_code',
        'message', 'Commerce payment intent currency must match the order currency'
      ));
    end if;

    if v_row ? 'payment_method_id' and v_row ->> 'payment_method_id' is not null then
      select pm.user_id
      into v_method_user_id
      from hfcc.commerce_payment_methods pm
      where pm.id = (v_row ->> 'payment_method_id')::uuid;

      if v_method_user_id is not null
         and v_order_user_id is not null
         and v_method_user_id is distinct from v_order_user_id then
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'kind', 'commerce',
          'field', 'payment_method_id',
          'message', 'Commerce payment method must belong to the order user'
        ));
      end if;
    end if;
  end if;

  -- Persist validation mismatches without raising an exception. Raising here
  -- would roll back the audit log record in the same transaction.
  if jsonb_array_length(v_errors) > 0 then
    if v_row ? 'id'
       and (v_row ->> 'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_entity_id := (v_row ->> 'id')::uuid;
    end if;

    if tg_table_name <> 'audit_logs' then
      insert into hfcc.audit_logs (
        actor_user_id,
        action_code,
        entity,
        entity_id,
        old_data,
        new_data,
        metadata
      )
      values (
        auth.uid(),
        'hfcc.audit_logs.action_code.validation_failed',
        tg_table_name,
        v_entity_id,
        v_old_row,
        v_row,
        jsonb_build_object(
          'operation', tg_op,
          'schema', tg_table_schema,
          'trigger', 'core_before_write',
          'errors', v_errors
        )
      );
    end if;

    raise warning 'core_before_write rejected %.% % because validation failed: %',
      tg_table_schema,
      tg_table_name,
      tg_op,
      v_errors;

    return null;
  end if;

  -- Optional versioning convention for future tables: an UPDATE on a table with
  -- a version column writes a new row with version + 1 and skips the in-place
  -- update. If the row has an id column, a new UUID is generated for the new
  -- version to avoid primary-key collision.
  if tg_op = 'UPDATE' and v_row ? 'version' then
    v_next_version := coalesce((v_old_row ->> 'version')::integer, 0) + 1;
    v_row := jsonb_set(v_row, '{version}', to_jsonb(v_next_version), true);

    if v_row ? 'id' then
      v_row := jsonb_set(v_row, '{id}', to_jsonb(extensions.gen_random_uuid()::text), true);
    end if;

    if v_row ? 'updated_at' then
      v_row := jsonb_set(v_row, '{updated_at}', to_jsonb(now()), true);
    end if;

    execute format(
      'insert into %I.%I select (jsonb_populate_record(null::%I.%I, $1)).*',
      tg_table_schema,
      tg_table_name,
      tg_table_schema,
      tg_table_name
    )
    using v_row;

    return null;
  end if;

  new := jsonb_populate_record(new, v_row);
  return new;
end;
$$;

comment on function hfcc.core_before_write() is
  'Unified BEFORE INSERT/UPDATE trigger function for updated_at maintenance, JSON schema validation, validation-error audit logging, user avatar ownership checks, commerce consistency checks, and optional versioned-row inserts.';

-- Attach one unified insert/update trigger to every HFCC table.
create or replace trigger core_before_write
before insert or update on hfcc.types
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.json_schemas
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.users
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.media
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.media_relations
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.settings
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.events_outbox
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.events_inbox
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.jobs
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.ledger_currencies
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.ledger_accounts
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.ledger_transactions
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.ledger_entries
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.ledger_wallet_grants
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.subscriptions
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.promotions
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.promotion_usages
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.commerce_products
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.commerce_orders
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.commerce_order_items
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.commerce_payment_methods
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.commerce_payment_intents
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.devices
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.outgoing_messages
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.activity_logs
for each row execute function hfcc.core_before_write();

create or replace trigger core_before_write
before insert or update on hfcc.audit_logs
for each row execute function hfcc.core_before_write();

comment on trigger core_before_write on hfcc.types is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.json_schemas is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.users is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, avatar ownership, and optional versioning.';
comment on trigger core_before_write on hfcc.media is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.media_relations is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.settings is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.events_outbox is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.events_inbox is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.jobs is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.ledger_currencies is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.ledger_accounts is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.ledger_transactions is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.ledger_entries is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.ledger_wallet_grants is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.subscriptions is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.promotions is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.promotion_usages is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.commerce_products is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.commerce_orders is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.commerce_order_items is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.commerce_payment_methods is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.commerce_payment_intents is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.devices is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.outgoing_messages is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.activity_logs is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';
comment on trigger core_before_write on hfcc.audit_logs is 'Unified insert/update trigger for updated_at, JSON schema validation, validation audit logging, and optional versioning.';

-- Attach the generic AFTER dispatcher to type-bearing tables where configured
-- invoke_functions, log_audit, or log_activity flags may need to react.
do $$
declare
  v_table regclass;
begin
  for v_table in
    select unnest(array[
      'hfcc.users'::regclass,
      'hfcc.settings'::regclass,
      'hfcc.media'::regclass,
      'hfcc.media_relations'::regclass,
      'hfcc.jobs'::regclass,
      'hfcc.events_inbox'::regclass,
      'hfcc.events_outbox'::regclass,
      'hfcc.ledger_currencies'::regclass,
      'hfcc.ledger_accounts'::regclass,
      'hfcc.ledger_transactions'::regclass,
      'hfcc.ledger_wallet_grants'::regclass,
      'hfcc.subscriptions'::regclass,
      'hfcc.promotions'::regclass,
      'hfcc.promotion_usages'::regclass,
      'hfcc.commerce_products'::regclass,
      'hfcc.commerce_orders'::regclass,
      'hfcc.commerce_order_items'::regclass,
      'hfcc.commerce_payment_methods'::regclass,
      'hfcc.commerce_payment_intents'::regclass,
      'hfcc.devices'::regclass,
      'hfcc.outgoing_messages'::regclass
    ])
  loop
    execute format('drop trigger if exists core_after_type_dispatch on %s', v_table);
    execute format(
      'create trigger core_after_type_dispatch after insert or update on %s for each row execute function hfcc.core_after_type_dispatch()',
      v_table
    );
    execute format(
      'comment on trigger core_after_type_dispatch on %s is %L',
      v_table,
      'Generic AFTER INSERT/UPDATE dispatcher for type-code invoke_functions, log_audit, and log_activity flags configured in hfcc.types.'
    );
  end loop;
end;
$$;

revoke all on function hfcc.invoke_type_handler(text, text, text, text, text, text, uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function hfcc.core_after_type_dispatch() from public, anon, authenticated;
revoke all on function hfcc.core_before_write() from public, anon, authenticated;
grant execute on function hfcc.invoke_type_handler(text, text, text, text, text, text, uuid, jsonb, jsonb) to service_role;
grant execute on function hfcc.core_after_type_dispatch() to service_role;
grant execute on function hfcc.core_before_write() to service_role;

-- ---------------------------------------------------------------------------
-- pg_cron scheduler
-- ---------------------------------------------------------------------------
-- pg_cron wakes the database worker every 10 seconds. Jobs and outbox events are
-- claimed by queue helpers; handler execution is dispatched by the generic
-- core_after_type_dispatch trigger when rows enter processing state.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null then
    raise exception 'pg_cron extension is not available. Enable pg_cron before running this migration.'
      using errcode = '0A000';
  end if;

  for v_jobid in
    execute 'select jobid from cron.job where jobname = $1'
    using 'core-process-due-jobs'
  loop
    execute 'select cron.unschedule($1)'
    using v_jobid;
  end loop;

  execute 'select cron.schedule($1, $2, $3)'
  using
    'core-process-due-jobs',
    '10 seconds',
    'select jsonb_build_object(''jobs'', hfcc.process_due_jobs(25), ''outbox'', hfcc.process_due_events_outbox(50));';
end;
$$;



