-- HOÀNG HẢI VNTD STORE — KHO KEY THẬT + TỰ ĐỘNG GIAO KEY KHI MUA BẰNG VÍ
-- Chạy sau schema-wallet.sql và schema-key-packages.sql trong Supabase SQL Editor.
-- Không xóa bảng products / orders / profiles / wallets hiện có.

create extension if not exists pgcrypto;

create table if not exists public.key_inventory (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.key_packages(id) on delete cascade,
  key_value text not null unique check (length(trim(key_value)) > 0),
  status text not null default 'available' check (status in ('available','sold')),
  order_id text,
  sold_to uuid references auth.users(id) on delete set null,
  sold_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists key_inventory_package_status_idx
  on public.key_inventory(package_id, status, created_at);
create index if not exists key_inventory_sold_to_idx
  on public.key_inventory(sold_to, sold_at desc);

alter table public.key_inventory enable row level security;
drop policy if exists "key_inventory_admin_all" on public.key_inventory;
create policy "key_inventory_admin_all" on public.key_inventory
  for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- Tự đồng bộ tồn kho gói mỗi khi ADMIN nạp KEY hoặc KEY được bán.
create or replace function public.sync_key_package_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package_id uuid;
begin
  v_package_id := coalesce(new.package_id, old.package_id);
  update public.key_packages kp
  set stock = (select count(*)::integer from public.key_inventory ki
               where ki.package_id = v_package_id and ki.status = 'available'),
      updated_at = now()
  where kp.id = v_package_id;
  if tg_op = 'UPDATE' and old.package_id is distinct from new.package_id then
    update public.key_packages kp
    set stock = (select count(*)::integer from public.key_inventory ki
                 where ki.package_id = old.package_id and ki.status = 'available'),
        updated_at = now()
    where kp.id = old.package_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists key_inventory_sync_package_stock on public.key_inventory;
create trigger key_inventory_sync_package_stock
after insert or update or delete on public.key_inventory
for each row execute function public.sync_key_package_stock();

-- Đồng bộ số tồn kho hiển thị với số KEY thật còn chưa bán.
update public.key_packages kp
set stock = (select count(*)::integer from public.key_inventory ki
             where ki.package_id = kp.id and ki.status = 'available'),
    updated_at = now();

create or replace function public.buy_key_package_with_wallet(p_package_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_pkg public.key_packages%rowtype;
  v_product public.products%rowtype;
  v_key public.key_inventory%rowtype;
  v_balance bigint;
  v_order_id text;
  v_item jsonb;
begin
  if v_user_id is null then raise exception 'Vui lòng đăng nhập trước khi mua'; end if;

  select * into v_pkg from public.key_packages where id = p_package_id for update;
  if not found then raise exception 'Không tìm thấy gói KEY'; end if;
  if not v_pkg.enabled then raise exception 'Gói KEY đang tạm ngừng bán'; end if;

  select * into v_product from public.products
  where id = v_pkg.product_id and active = true;
  if not found then raise exception 'Sản phẩm hiện không còn được bán'; end if;
  if v_pkg.price < 1 then raise exception 'Giá gói KEY chưa hợp lệ'; end if;

  -- Chỉ giao KEY thật đang available; không dùng số stock nhập tay làm KEY giả.
  select * into v_key from public.key_inventory
  where package_id = v_pkg.id and status = 'available'
  order by created_at, id
  limit 1 for update skip locked;
  if not found then
    update public.key_packages set stock = 0, updated_at = now() where id = v_pkg.id;
    raise exception 'Kho KEY thật đã hết. Vui lòng quay lại sau';
  end if;

  insert into public.wallets(user_id, balance) values (v_user_id, 0)
  on conflict (user_id) do nothing;
  select balance into v_balance from public.wallets where user_id = v_user_id for update;
  if v_balance < v_pkg.price then raise exception 'Số dư ví không đủ. Vui lòng nạp thêm tiền'; end if;

  update public.wallets set balance = balance - v_pkg.price, updated_at = now()
  where user_id = v_user_id;

  v_item := jsonb_build_array(jsonb_build_object(
    'product_id', v_product.id,
    'product_name', v_product.name,
    'package_id', v_pkg.id,
    'package_name', v_pkg.name,
    'quantity', 1,
    'unit_price', v_pkg.price,
    'delivered_keys', jsonb_build_array(v_key.key_value)
  ));

  insert into public.orders(user_id, total_amount, status, items)
  values (v_user_id, v_pkg.price, 'completed', v_item)
  returning id::text into v_order_id;

  update public.key_inventory
  set status = 'sold', order_id = v_order_id, sold_to = v_user_id, sold_at = now()
  where id = v_key.id and status = 'available';
  if not found then raise exception 'KEY vừa được người khác mua. Vui lòng thử lại'; end if;

  insert into public.wallet_transactions(user_id, amount, type, reference_id, note)
  values (v_user_id, -v_pkg.price, 'purchase', null,
          'Mua ' || v_product.name || ' - ' || v_pkg.name || ' - Đơn #' || v_order_id);

  update public.key_packages kp
  set stock = (select count(*)::integer from public.key_inventory ki
               where ki.package_id = kp.id and ki.status = 'available'),
      updated_at = now()
  where kp.id = v_pkg.id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'amount', v_pkg.price,
    'package_name', v_pkg.name,
    'delivered_key', v_key.key_value,
    'remaining_balance', v_balance - v_pkg.price,
    'remaining_stock', (select count(*) from public.key_inventory where package_id = v_pkg.id and status = 'available')
  );
end;
$$;

revoke all on function public.buy_key_package_with_wallet(uuid) from public;
grant execute on function public.buy_key_package_with_wallet(uuid) to authenticated;

-- Yêu cầu PostgREST nạp lại schema cache để website nhận hàm RPC mới.
notify pgrst, 'reload schema';
