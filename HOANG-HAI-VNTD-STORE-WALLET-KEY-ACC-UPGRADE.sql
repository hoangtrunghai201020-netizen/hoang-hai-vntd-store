

-- ===================== BEGIN schema-wallet.sql =====================
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
grant execute on function public.hhvntd_is_admin() to anon, authenticated;
grant execute on function public.approve_wallet_deposit(uuid) to authenticated;
grant execute on function public.reject_wallet_deposit(uuid) to authenticated;

-- ===================== END schema-wallet.sql =====================



-- ===================== BEGIN schema-key-packages.sql =====================
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

-- ===================== END schema-key-packages.sql =====================



-- ===================== BEGIN schema-key-delivery.sql =====================
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

-- ===================== END schema-key-delivery.sql =====================



-- ===================== BEGIN SCHEMA-ACC-CLONE.sql =====================
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
  if p_accounts is null or jsonb_typeof(p_accounts)<>'array' then raise exception 'Danh sách ACC không hợp lệ'; end if;
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
  if v_pkg.price is null or v_pkg.price <= 0 then raise exception 'Giá gói ACC chưa hợp lệ'; end if;
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

-- ===================== END SCHEMA-ACC-CLONE.sql =====================



-- ===================== FIX: CHECKOUT BẰNG VÍ CHO SẢN PHẨM THƯỜNG =====================
-- Giá được đọc trực tiếp từ public.products; không tin giá do trình duyệt gửi lên.
-- Mỗi lần mua: khóa ví + sản phẩm, kiểm tra tiền/kho, tạo đơn, trừ tiền, ghi lịch sử.
-- Nếu một bước lỗi, toàn bộ giao dịch tự rollback.

create or replace function public.checkout_with_wallet(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_wallet_balance bigint;
  v_total bigint := 0;
  v_order_id text;
  v_items jsonb := '[]'::jsonb;
  v_row record;
  v_product public.products%rowtype;
begin
  if v_user_id is null then
    raise exception 'Bạn cần đăng nhập để thanh toán';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1
     or jsonb_array_length(p_items) > 50 then
    raise exception 'Giỏ hàng không hợp lệ';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) as e(value)
    where jsonb_typeof(e.value) <> 'object'
       or coalesce(e.value->>'product_id','') = ''
       or coalesce(e.value->>'quantity','') !~ '^[0-9]+$'
       or (e.value->>'quantity')::integer < 1
       or (e.value->>'quantity')::integer > 100
  ) then
    raise exception 'Sản phẩm hoặc số lượng không hợp lệ';
  end if;

  -- Không cho phép mua sản phẩm KEY qua luồng thường; KEY phải đi qua kho KEY thật.
  if exists (
    select 1
    from jsonb_array_elements(p_items) as e(value)
    join public.products p on p.id = (e.value->>'product_id')::uuid
    where lower(coalesce(p.name,'') || ' ' || coalesce(p.category,'')) like '%key%'
  ) then
    raise exception 'Sản phẩm KEY phải được mua bằng chức năng CHỌN GÓI';
  end if;

  insert into public.wallets(user_id, balance)
  values (v_user_id, 0)
  on conflict (user_id) do nothing;

  select balance into v_wallet_balance
  from public.wallets
  where user_id = v_user_id
  for update;

  for v_row in
    select (e.value->>'product_id')::uuid as product_id,
           sum((e.value->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as e(value)
    group by (e.value->>'product_id')::uuid
    order by (e.value->>'product_id')::uuid
  loop
    select * into v_product
    from public.products
    where id = v_row.product_id
    for update;

    if not found or v_product.active is not true then
      raise exception 'Có sản phẩm không tồn tại hoặc đã ngừng bán';
    end if;
    if v_product.stock < v_row.quantity then
      raise exception 'Sản phẩm "%" không đủ tồn kho', v_product.name;
    end if;
    if v_product.price is null or v_product.price <= 0 then
      raise exception 'Giá sản phẩm không hợp lệ hoặc đang bằng 0';
    end if;

    v_total := v_total + (v_product.price * v_row.quantity);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_product.id,
      'product_name', v_product.name,
      'quantity', v_row.quantity,
      'unit_price', v_product.price
    ));
  end loop;

  if v_wallet_balance < v_total then
    raise exception 'Số dư ví không đủ. Cần %, hiện có % VND', v_total, v_wallet_balance;
  end if;

  for v_row in
    select (e.value->>'product_id')::uuid as product_id,
           sum((e.value->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as e(value)
    group by (e.value->>'product_id')::uuid
    order by (e.value->>'product_id')::uuid
  loop
    update public.products
    set stock = stock - v_row.quantity
    where id = v_row.product_id
      and active = true
      and stock >= v_row.quantity;
    if not found then
      raise exception 'Tồn kho vừa thay đổi. Vui lòng tải lại giỏ hàng';
    end if;
  end loop;

  insert into public.orders(user_id, total_amount, status, items)
  values (v_user_id, v_total, 'paid', v_items)
  returning id::text into v_order_id;

  update public.wallets
  set balance = balance - v_total,
      updated_at = now()
  where user_id = v_user_id;

  if v_total > 0 then
    insert into public.wallet_transactions(user_id, amount, type, note)
    values (v_user_id, -v_total, 'purchase', 'Thanh toán đơn hàng #' || v_order_id);
  end if;

  return jsonb_build_object(
    'order_id', v_order_id,
    'total_amount', v_total,
    'balance', v_wallet_balance - v_total,
    'status', 'paid'
  );
end;
$$;

-- Không cho trình duyệt tự tạo đơn chờ thanh toán mà không trừ ví.
revoke insert on public.orders from anon, authenticated;
revoke all on function public.checkout_with_wallet(jsonb) from public;
revoke all on function public.checkout_with_wallet(jsonb) from anon;
grant execute on function public.checkout_with_wallet(jsonb) to authenticated;

notify pgrst, 'reload schema';


-- ===================== PUBLIC TRUST BOARD (ANONYMIZED) =====================
-- Shows approved deposits leaderboard and successful recent purchases.
-- Never exposes email, phone, key values, passwords, or account credentials.
create or replace function public.hhvntd_public_top_depositors()
returns table(customer_label text,total_deposited bigint,deposit_count bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    'Khách #' || upper(substr(md5(wt.user_id::text),1,4)) as customer_label,
    sum(wt.amount)::bigint as total_deposited,
    count(*)::bigint as deposit_count
  from public.wallet_transactions wt
  where wt.type = 'deposit' and wt.amount > 0
  group by wt.user_id
  order by sum(wt.amount) desc, count(*) desc
  limit 10;
$$;

create or replace function public.hhvntd_public_recent_purchases()
returns table(customer_label text,item_label text,total_amount bigint,purchased_at timestamptz)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    'Khách #' || upper(substr(md5(o.user_id::text),1,4)) as customer_label,
    coalesce(
      nullif(left(string_agg(coalesce(e.item->>'package_name',e.item->>'product_name',e.item->>'name','Sản phẩm số'), ', ' order by e.ord),90),''),
      'Sản phẩm số'
    ) as item_label,
    o.total_amount::bigint,
    o.created_at
  from public.orders o
  left join lateral jsonb_array_elements(
    case when jsonb_typeof(o.items)='array' then o.items else '[]'::jsonb end
  ) with ordinality as e(item,ord) on true
  where lower(coalesce(o.status,'')) in ('paid','completed','processing')
  group by o.id,o.user_id,o.total_amount,o.created_at
  order by o.created_at desc
  limit 12;
$$;

revoke all on function public.hhvntd_public_top_depositors() from public;
revoke all on function public.hhvntd_public_recent_purchases() from public;
grant execute on function public.hhvntd_public_top_depositors() to anon, authenticated;
grant execute on function public.hhvntd_public_recent_purchases() to anon, authenticated;
notify pgrst,'reload schema';
-- ===================== END PUBLIC TRUST BOARD =====================


-- ===================== FIX: PROFILE NAME + PRODUCT REVIEWS =====================
-- Bổ sung các đối tượng mà giao diện hiện tại đang gọi; không xóa dữ liệu cũ.
alter table public.profiles add column if not exists full_name text;

create table if not exists public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text not null default '',
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id,user_id)
);
-- Tương thích cả bảng đánh giá đã được tạo bởi schema-customer-reviews.sql cũ.
alter table public.product_reviews add column if not exists is_hidden boolean not null default false;
alter table public.product_reviews add column if not exists is_visible boolean not null default true;
alter table public.product_reviews add column if not exists author_name text not null default 'Khách hàng';
alter table public.product_reviews add column if not exists updated_at timestamptz not null default now();
update public.product_reviews set is_hidden = not is_visible where is_hidden is distinct from (not is_visible);
create index if not exists product_reviews_product_created_idx
  on public.product_reviews(product_id,created_at desc);
alter table public.product_reviews enable row level security;
-- Dọn các policy tên cũ của schema-customer-reviews.sql để tránh kiểm tra quyền chồng chéo.
drop policy if exists "reviews visible public or admin" on public.product_reviews;
drop policy if exists "admin update reviews" on public.product_reviews;
drop policy if exists "admin delete reviews" on public.product_reviews;
drop policy if exists product_reviews_public_visible on public.product_reviews;
create policy product_reviews_public_visible on public.product_reviews
  for select to anon,authenticated using (is_hidden=false or public.hhvntd_is_admin());
drop policy if exists product_reviews_admin_manage on public.product_reviews;
create policy product_reviews_admin_manage on public.product_reviews
  for all to authenticated using (public.hhvntd_is_admin())
  with check (public.hhvntd_is_admin());
grant select on public.product_reviews to anon,authenticated;
grant insert,update,delete on public.product_reviews to authenticated;

create or replace function public.set_my_profile_name(p_full_name text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Vui lòng đăng nhập'; end if;
  if length(trim(coalesce(p_full_name,'')))<2 or length(trim(p_full_name))>100 then
    raise exception 'Họ tên phải có từ 2 đến 100 ký tự';
  end if;
  update public.profiles set full_name=trim(p_full_name) where id=auth.uid();
  if not found then raise exception 'Không tìm thấy hồ sơ tài khoản'; end if;
end; $$;

create or replace function public.submit_product_review(p_product_id uuid,p_rating integer,p_comment text default '')
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'Vui lòng đăng nhập'; end if;
  if p_rating is null or p_rating<1 or p_rating>5 then raise exception 'Điểm đánh giá phải từ 1 đến 5'; end if;
  if not exists(select 1 from public.products p where p.id=p_product_id and p.active=true) then
    raise exception 'Sản phẩm không tồn tại hoặc đã ngừng bán';
  end if;
  if not exists(
    select 1 from public.orders o
    cross join lateral jsonb_array_elements(case when jsonb_typeof(o.items)='array' then o.items else '[]'::jsonb end) i(item)
    where o.user_id=v_uid and lower(coalesce(o.status,'')) in ('completed','paid')
      and i.item->>'product_id'=p_product_id::text
  ) then raise exception 'Chỉ khách đã mua sản phẩm và có đơn thanh toán thành công mới được đánh giá'; end if;
  insert into public.product_reviews(product_id,user_id,rating,comment,is_hidden,updated_at)
  values(p_product_id,v_uid,p_rating,left(coalesce(p_comment,''),1000),false,now())
  on conflict(product_id,user_id) do update set rating=excluded.rating,comment=excluded.comment,is_hidden=false,is_visible=true,updated_at=now()
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.admin_set_review_visibility(p_review_id uuid,p_hidden boolean)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.hhvntd_is_admin() then raise exception 'Không có quyền ADMIN'; end if;
  update public.product_reviews set is_hidden=coalesce(p_hidden,false),is_visible=not coalesce(p_hidden,false),updated_at=now() where id=p_review_id;
  if not found then raise exception 'Không tìm thấy đánh giá'; end if;
end; $$;

revoke all on function public.set_my_profile_name(text) from public;
revoke all on function public.submit_product_review(uuid,integer,text) from public;
revoke all on function public.admin_set_review_visibility(uuid,boolean) from public;
grant execute on function public.set_my_profile_name(text) to authenticated;
grant execute on function public.submit_product_review(uuid,integer,text) to authenticated;
grant execute on function public.admin_set_review_visibility(uuid,boolean) to authenticated;

-- Quyền SQL cần thiết; RLS vẫn giới hạn thao tác kho KEY cho ADMIN.
grant select on public.key_packages to anon,authenticated;
grant insert,update,delete on public.key_packages to authenticated;
grant select,insert,update,delete on public.key_inventory to authenticated;
notify pgrst,'reload schema';
-- ===================== END FIX: PROFILE NAME + PRODUCT REVIEWS =====================


-- ===================== KIỂM TRA SAU NÂNG CẤP =====================
-- Các truy vấn chỉ đọc, có thể chạy riêng sau khi toàn bộ SQL phía trên báo Success.
-- 1) Xác nhận các hàm thanh toán tồn tại:
select p.proname as purchase_function, pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'checkout_with_wallet','buy_key_package_with_wallet','buy_acc_clone_with_wallet',
  'approve_wallet_deposit','reject_wallet_deposit'
) order by p.proname;

-- 2) Kiểm tra ví âm (kết quả đúng phải là 0 dòng):
select user_id,balance from public.wallets where balance < 0;

-- 3) Kiểm tra số tồn KEY/ACC so với kho thật:
select kp.id,kp.name,kp.stock,
  (select count(*) from public.key_inventory ki where ki.package_id=kp.id and ki.status='available') as actual_stock
from public.key_packages kp order by kp.created_at desc;
select ap.id,ap.name,ap.stock,
  (select count(*) from public.acc_clone_inventory ai where ai.package_id=ap.id and ai.status='available') as actual_stock
from public.acc_clone_packages ap order by ap.created_at desc;
-- Không tự chạy giao dịch thử hoặc tự cộng/trừ tiền trong các câu kiểm tra này.
-- ===================== END KIỂM TRA SAU NÂNG CẤP =====================


-- ===================== ACC CLONE BULK RESTOCK =====================
-- Create package once, then add many accounts to that existing package.
create or replace function public.admin_add_acc_clone_inventory(p_package_id uuid,p_accounts jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_inserted integer := 0;
  v_submitted integer := 0;
begin
  if not public.hhvntd_is_admin() then raise exception 'Chỉ ADMIN được nạp ACC CLONE'; end if;
  if p_package_id is null or not exists(select 1 from public.acc_clone_packages where id=p_package_id) then
    raise exception 'Không tìm thấy gói ACC CLONE';
  end if;
  if p_accounts is null or jsonb_typeof(p_accounts)<>'array' or jsonb_array_length(p_accounts)<1 or jsonb_array_length(p_accounts)>2000 then
    raise exception 'Danh sách ACC phải có từ 1 đến 2000 dòng';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_accounts) a
    where jsonb_typeof(a)<>'object'
       or length(trim(coalesce(a->>'login','')))=0
       or length(coalesce(a->>'password',''))=0
       or length(trim(coalesce(a->>'login','')))>320
       or length(coalesce(a->>'password',''))>2000
  ) then raise exception 'Có dòng ACC sai định dạng hoặc quá dài'; end if;
  select count(*)::integer into v_submitted from jsonb_array_elements(p_accounts);
  insert into public.acc_clone_inventory(package_id,login,password)
  select p_package_id,trim(a->>'login'),a->>'password'
  from jsonb_array_elements(p_accounts) a
  on conflict(login_key) do nothing;
  get diagnostics v_inserted=row_count;
  update public.acc_clone_packages p
    set stock=(select count(*)::integer from public.acc_clone_inventory i where i.package_id=p.id and i.status='available'),updated_at=now()
    where p.id=p_package_id;
  return jsonb_build_object('inserted',v_inserted,'skipped',v_submitted-v_inserted,'submitted',v_submitted);
end;
$$;
revoke all on function public.admin_add_acc_clone_inventory(uuid,jsonb) from public;
grant execute on function public.admin_add_acc_clone_inventory(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
-- ===================== END ACC CLONE BULK RESTOCK =====================


-- Create an empty ACC package once; bulk inventory is added with admin_add_acc_clone_inventory.
create or replace function public.admin_create_empty_acc_clone_package(p_name text,p_price bigint)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
  if not public.hhvntd_is_admin() then raise exception 'Chỉ ADMIN được tạo gói ACC CLONE'; end if;
  if length(trim(coalesce(p_name,'')))<2 or length(trim(p_name))>120 or p_price is null or p_price<1 then raise exception 'Tên gói hoặc giá bán không hợp lệ'; end if;
  insert into public.acc_clone_packages(name,price,stock,enabled) values(trim(p_name),p_price,0,true) returning id into v_id;
  return v_id;
end; $$;
revoke all on function public.admin_create_empty_acc_clone_package(text,bigint) from public;
grant execute on function public.admin_create_empty_acc_clone_package(text,bigint) to authenticated;
notify pgrst,'reload schema';
