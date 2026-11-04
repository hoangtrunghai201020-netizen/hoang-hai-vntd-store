-- HOÀNG HẢI VNTD STORE — KHO KEY THEO TỪNG GÓI
-- Chạy một lần trong Supabase > SQL Editor > New query.
-- Không xóa hoặc sửa các bảng products, orders, profiles hay wallet.

create table if not exists public.key_packages (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  price bigint not null default 0 check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  enabled boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id, name)
);

create index if not exists key_packages_product_id_idx
  on public.key_packages(product_id);

alter table public.key_packages enable row level security;

drop policy if exists "Anyone can view key packages" on public.key_packages;
create policy "Anyone can view key packages"
  on public.key_packages for select
  to anon, authenticated
  using (true);

drop policy if exists "Admins can insert key packages" on public.key_packages;
create policy "Admins can insert key packages"
  on public.key_packages for insert
  to authenticated
  with check (exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  ));

drop policy if exists "Admins can update key packages" on public.key_packages;
create policy "Admins can update key packages"
  on public.key_packages for update
  to authenticated
  using (exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  ))
  with check (exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  ));

drop policy if exists "Admins can delete key packages" on public.key_packages;
create policy "Admins can delete key packages"
  on public.key_packages for delete
  to authenticated
  using (exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  ));

-- Sau khi chạy thành công, mở ADMIN trên shop để thêm các gói KEY cho từng sản phẩm.
-- Không tự tạo số lượng/giá mẫu để tránh hiển thị sai kho thật.
