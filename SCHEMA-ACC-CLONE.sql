-- HOÀNG HẢI VNTD STORE — KHO ACC CLONE RIÊNG
-- Chạy SAU schema-wallet.sql và các SQL kho KEY hiện có.
-- Không sửa/xóa products, orders, profiles, wallets, key_packages hoặc key_inventory.

create extension if not exists pgcrypto;

create table if not exists public.acc_clone_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  price bigint not null check (price > 0),
  stock integer not null default 0 check (stock >= 0),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.acc_clone_inventory (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.acc_clone_packages(id) on delete cascade,
  login text not null,
  password text not null,
  login_key text generated always as (lower(trim(login))) stored,
  status text not null default 'available' check (status in ('available','sold')),
  order_id text,
  sold_to uuid references auth.users(id) on delete set null,
  sold_at timestamptz,
  created_at timestamptz not null default now(),
  unique(login_key)
);
create index if not exists acc_clone_inventory_available_idx
  on public.acc_clone_inventory(package_id,status,created_at);

alter table public.acc_clone_packages enable row level security;
alter table public.acc_clone_inventory enable row level security;
drop policy if exists acc_clone_packages_public_read on public.acc_clone_packages;
create policy acc_clone_packages_public_read on public.acc_clone_packages
  for select to anon, authenticated using (enabled = true or public.hhvntd_is_admin());
drop policy if exists acc_clone_packages_admin_write on public.acc_clone_packages;
create policy acc_clone_packages_admin_write on public.acc_clone_packages
  for all to authenticated using (public.hhvntd_is_admin()) with check (public.hhvntd_is_admin());
drop policy if exists acc_clone_inventory_admin_only on public.acc_clone_inventory;
create policy acc_clone_inventory_admin_only on public.acc_clone_inventory
  for all to authenticated using (public.hhvntd_is_admin()) with check (public.hhvntd_is_admin());

create or replace function public.sync_acc_clone_stock()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  v_id := coalesce(new.package_id,old.package_id);
  update public.acc_clone_packages p set stock=(select count(*)::integer from public.acc_clone_inventory i where i.package_id=v_id and i.status='available'),updated_at=now() where p.id=v_id;
  if tg_op='UPDATE' and old.package_id is distinct from new.package_id then
    update public.acc_clone_packages p set stock=(select count(*)::integer from public.acc_clone_inventory i where i.package_id=old.package_id and i.status='available'),updated_at=now() where p.id=old.package_id;
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end; $$;
drop trigger if exists acc_clone_inventory_sync_stock on public.acc_clone_inventory;
create trigger acc_clone_inventory_sync_stock after insert or update or delete on public.acc_clone_inventory for each row execute function public.sync_acc_clone_stock();

create or replace function public.admin_create_acc_clone_package(p_name text,p_price bigint,p_accounts jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_package uuid; v_inserted integer;
begin
  if not public.hhvntd_is_admin() then raise exception 'Chỉ ADMIN được nạp ACC CLONE'; end if;
  if length(trim(coalesce(p_name,'')))=0 or p_price<=0 then raise exception 'Tên gói hoặc giá bán không hợp lệ'; end if;
  if jsonb_typeof(p_accounts)<>'array' or jsonb_array_length(p_accounts)=0 then raise exception 'Danh sách ACC trống'; end if;
  insert into public.acc_clone_packages(name,price) values(trim(p_name),p_price) returning id into v_package;
  insert into public.acc_clone_inventory(package_id,login,password)
  select v_package,trim(x->>'login'),x->>'password'
  from jsonb_array_elements(p_accounts) x
  where length(trim(coalesce(x->>'login','')))>0 and length(coalesce(x->>'password',''))>0
  on conflict(login_key) do nothing;
  get diagnostics v_inserted=row_count;
  return jsonb_build_object('package_id',v_package,'inserted',v_inserted,'submitted',jsonb_array_length(p_accounts));
end; $$;

create or replace function public.buy_acc_clone_with_wallet(p_package_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_pkg public.acc_clone_packages%rowtype; v_acc public.acc_clone_inventory%rowtype; v_balance bigint; v_order_id text;
begin
  if v_uid is null then raise exception 'Vui lòng đăng nhập'; end if;
  select * into v_pkg from public.acc_clone_packages where id=p_package_id and enabled=true for update;
  if not found then raise exception 'Gói ACC không tồn tại hoặc đã tạm ngừng'; end if;
  select * into v_acc from public.acc_clone_inventory where package_id=p_package_id and status='available' order by created_at,id limit 1 for update skip locked;
  if not found then raise exception 'Gói ACC đã hết hàng'; end if;
  insert into public.wallets(user_id,balance) values(v_uid,0) on conflict(user_id) do nothing;
  select balance into v_balance from public.wallets where user_id=v_uid for update;
  if v_balance<v_pkg.price then raise exception 'Số dư ví không đủ. Vui lòng nạp thêm tiền'; end if;
  update public.wallets set balance=balance-v_pkg.price,updated_at=now() where user_id=v_uid;
  insert into public.orders(user_id,total_amount,status,items)
  values(v_uid,v_pkg.price,'completed',jsonb_build_array(jsonb_build_object('type','acc_clone','package_id',v_pkg.id,'package_name',v_pkg.name,'quantity',1,'unit_price',v_pkg.price,'delivered_login',v_acc.login,'delivered_password',v_acc.password)))
  returning id::text into v_order_id;
  update public.acc_clone_inventory set status='sold',order_id=v_order_id,sold_to=v_uid,sold_at=now() where id=v_acc.id and status='available';
  if not found then raise exception 'ACC vừa được người khác mua. Vui lòng thử lại'; end if;
  insert into public.wallet_transactions(user_id,amount,type,reference_id,note)
  values(v_uid,-v_pkg.price,'purchase',null,'Mua ACC CLONE - '||v_pkg.name||' - Đơn #'||v_order_id);
  update public.acc_clone_packages set stock=(select count(*)::integer from public.acc_clone_inventory where package_id=v_pkg.id and status='available'),updated_at=now() where id=v_pkg.id;
  return jsonb_build_object('order_id',v_order_id,'amount',v_pkg.price,'package_name',v_pkg.name,'delivered_login',v_acc.login,'delivered_password',v_acc.password,'remaining_balance',v_balance-v_pkg.price);
end; $$;

revoke all on function public.admin_create_acc_clone_package(text,bigint,jsonb) from public;
grant execute on function public.admin_create_acc_clone_package(text,bigint,jsonb) to authenticated;
revoke all on function public.buy_acc_clone_with_wallet(uuid) from public;
grant execute on function public.buy_acc_clone_with_wallet(uuid) to authenticated;
grant select on public.acc_clone_packages to anon,authenticated;
grant select,insert,update,delete on public.acc_clone_packages to authenticated;
grant select,insert,update,delete on public.acc_clone_inventory to authenticated;
notify pgrst,'reload schema';
