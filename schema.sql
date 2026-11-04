-- HOÀNG HẢI VNTD STORE — Supabase schema
create extension if not exists pgcrypto;
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'customer' check (role in ('customer','admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null,
  description text not null default '',
  price bigint not null check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  sku text not null unique,
  icon text not null default '✦',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id),
  total_amount bigint not null check (total_amount >= 0),
  status text not null default 'pending_payment' check (status in ('pending_payment','paid','processing','completed','cancelled')),
  items jsonb not null,
  created_at timestamptz not null default now()
);
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
create policy "profiles read own or admin" on public.profiles for select using (id=auth.uid() or public.is_admin());
create policy "customers read active products" on public.products for select using (active=true or public.is_admin());
create policy "admin insert products" on public.products for insert with check (public.is_admin());
create policy "admin update products" on public.products for update using (public.is_admin()) with check (public.is_admin());
create policy "admin delete products" on public.products for delete using (public.is_admin());
create policy "customer read own orders" on public.orders for select using (user_id=auth.uid() or public.is_admin());
create policy "customer create own orders" on public.orders for insert with check (user_id=auth.uid());
create policy "admin update orders" on public.orders for update using (public.is_admin()) with check (public.is_admin());
-- Create profile after signup. Role is always customer; never accept role from client.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$ begin insert into public.profiles(id,email,role) values(new.id,new.email,'customer'); return new; end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();
-- After creating your account, promote ONLY your own verified account from Supabase SQL Editor:
-- update public.profiles set role='admin' where email='YOUR_ADMIN_EMAIL';
-- Do not expose service_role keys in frontend code.
