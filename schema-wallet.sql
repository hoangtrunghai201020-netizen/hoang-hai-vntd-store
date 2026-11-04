-- HOÀNG HẢI VNTD STORE — WALLET / NẠP TIỀN VND
-- Chạy đoạn SQL này trong Supabase > SQL Editor > New query.
-- Không sửa hoặc xóa bảng products/orders/profiles hiện có.
-- ADMIN là user có profiles.role = 'admin'.

create extension if not exists pgcrypto;

create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.deposit_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount >= 10000),
  transfer_note text not null,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);

create table if not exists public.wallet_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount <> 0),
  type text not null check (type in ('deposit','purchase','refund','adjustment')),
  reference_id uuid,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists deposit_requests_user_created_idx
  on public.deposit_requests(user_id, created_at desc);
create index if not exists wallet_transactions_user_created_idx
  on public.wallet_transactions(user_id, created_at desc);

create or replace function public.hhvntd_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  );
$$;

alter table public.wallets enable row level security;
alter table public.deposit_requests enable row level security;
alter table public.wallet_transactions enable row level security;

drop policy if exists "wallet_read_own" on public.wallets;
create policy "wallet_read_own" on public.wallets
  for select to authenticated using (user_id = auth.uid() or public.hhvntd_is_admin());

drop policy if exists "deposit_read_own_or_admin" on public.deposit_requests;
create policy "deposit_read_own_or_admin" on public.deposit_requests
  for select to authenticated using (user_id = auth.uid() or public.hhvntd_is_admin());

drop policy if exists "deposit_create_own" on public.deposit_requests;
create policy "deposit_create_own" on public.deposit_requests
  for insert to authenticated with check (
    user_id = auth.uid() and status = 'pending' and amount >= 10000
  );

drop policy if exists "wallet_transactions_read_own_or_admin" on public.wallet_transactions;
create policy "wallet_transactions_read_own_or_admin" on public.wallet_transactions
  for select to authenticated using (user_id = auth.uid() or public.hhvntd_is_admin());

-- Không cấp quyền INSERT/UPDATE trực tiếp cho khách vào wallets hoặc wallet_transactions.
revoke all on public.wallets from anon, authenticated;
grant select on public.wallets to authenticated;
revoke all on public.wallet_transactions from anon, authenticated;
grant select on public.wallet_transactions to authenticated;
revoke all on public.deposit_requests from anon, authenticated;
grant select, insert on public.deposit_requests to authenticated;

create or replace function public.approve_wallet_deposit(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  req public.deposit_requests%rowtype;
begin
  if not public.hhvntd_is_admin() then
    raise exception 'Không có quyền ADMIN';
  end if;

  select * into req
  from public.deposit_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Không tìm thấy yêu cầu nạp'; end if;
  if req.status <> 'pending' then raise exception 'Yêu cầu này đã được xử lý'; end if;

  insert into public.wallets(user_id, balance)
  values (req.user_id, req.amount)
  on conflict (user_id) do update
    set balance = public.wallets.balance + excluded.balance,
        updated_at = now();

  insert into public.wallet_transactions(user_id, amount, type, reference_id, note)
  values (req.user_id, req.amount, 'deposit', req.id, 'Nạp tiền được ADMIN duyệt');

  update public.deposit_requests
  set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
  where id = req.id;
end;
$$;

create or replace function public.reject_wallet_deposit(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  req public.deposit_requests%rowtype;
begin
  if not public.hhvntd_is_admin() then
    raise exception 'Không có quyền ADMIN';
  end if;

  select * into req
  from public.deposit_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Không tìm thấy yêu cầu nạp'; end if;
  if req.status <> 'pending' then raise exception 'Yêu cầu này đã được xử lý'; end if;

  update public.deposit_requests
  set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
  where id = req.id;
end;
$$;

revoke all on function public.hhvntd_is_admin() from public;
revoke all on function public.approve_wallet_deposit(uuid) from public;
revoke all on function public.reject_wallet_deposit(uuid) from public;
grant execute on function public.hhvntd_is_admin() to authenticated;
grant execute on function public.approve_wallet_deposit(uuid) to authenticated;
grant execute on function public.reject_wallet_deposit(uuid) to authenticated;
