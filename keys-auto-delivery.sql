-- HOÀNG HẢI VNTD — KHO KEY + TỰ ĐỘNG GIAO KEY SAU THANH TOÁN
-- Chạy sau schema.sql, schema-wallet.sql và checkout-wallet.sql.
-- Không xóa/sửa các bảng products, orders, profiles hoặc wallets.

create table if not exists public.product_keys (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  key_text text not null,
  status text not null default 'available' check (status in ('available','sold')),
  order_id bigint references public.orders(id),
  user_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  sold_at timestamptz,
  unique(product_id, key_text)
);
create index if not exists product_keys_available_idx
  on public.product_keys(product_id, created_at, id) where status='available';
create index if not exists product_keys_order_idx
  on public.product_keys(order_id) where status='sold';

alter table public.product_keys enable row level security;
drop policy if exists "product_keys_admin_read" on public.product_keys;
create policy "product_keys_admin_read" on public.product_keys
  for select to authenticated using (public.hhvntd_is_admin());
drop policy if exists "product_keys_admin_insert" on public.product_keys;
create policy "product_keys_admin_insert" on public.product_keys
  for insert to authenticated with check (public.hhvntd_is_admin() and status='available' and order_id is null and user_id is null);
drop policy if exists "product_keys_admin_delete_available" on public.product_keys;
create policy "product_keys_admin_delete_available" on public.product_keys
  for delete to authenticated using (public.hhvntd_is_admin() and status='available');
revoke all on public.product_keys from anon, authenticated;
grant select, insert, delete on public.product_keys to authenticated;

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
  v_order_id bigint;
  v_items jsonb := '[]'::jsonb;
  v_row record;
  v_product public.products%rowtype;
  v_key_ids uuid[];
  v_keys jsonb;
  v_key_count integer;
begin
  if v_user_id is null then raise exception 'Bạn cần đăng nhập để thanh toán'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
    raise exception 'Giỏ hàng không hợp lệ';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) as e(value)
    where jsonb_typeof(e.value) <> 'object'
       or coalesce(e.value->>'product_id','') = ''
       or coalesce(e.value->>'quantity','') !~ '^[0-9]+$'
       or (e.value->>'quantity')::integer < 1
       or (e.value->>'quantity')::integer > 100
  ) then raise exception 'Sản phẩm hoặc số lượng không hợp lệ'; end if;

  insert into public.wallets(user_id,balance) values(v_user_id,0)
  on conflict(user_id) do nothing;
  select balance into v_wallet_balance from public.wallets
  where user_id=v_user_id for update;

  -- Khóa từng sản phẩm để hai giao dịch không thể lấy cùng một key.
  for v_row in
    select (e.value->>'product_id')::uuid as product_id,
           sum((e.value->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as e(value)
    group by (e.value->>'product_id')::uuid
    order by (e.value->>'product_id')::uuid
  loop
    select * into v_product from public.products where id=v_row.product_id for update;
    if not found or v_product.active is not true then
      raise exception 'Có sản phẩm không tồn tại hoặc đã ngừng bán';
    end if;
    if v_product.stock < v_row.quantity then
      raise exception 'Sản phẩm "%" không đủ tồn kho',v_product.name;
    end if;

    select coalesce(array_agg(k.id),array[]::uuid[]),
           coalesce(jsonb_agg(k.key_text),'[]'::jsonb),count(*)::integer
      into v_key_ids,v_keys,v_key_count
    from (
      select id,key_text from public.product_keys
      where product_id=v_product.id and status='available'
      order by created_at,id limit v_row.quantity for update
    ) k;
    if v_key_count <> v_row.quantity then
      raise exception 'Sản phẩm "%" không đủ key trong kho',v_product.name;
    end if;

    v_total := v_total + (v_product.price * v_row.quantity);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,
      'product_name',v_product.name,
      'quantity',v_row.quantity,
      'unit_price',v_product.price,
      'delivered_keys',v_keys,
      'key_ids_internal',to_jsonb(v_key_ids)
    ));
  end loop;

  if v_wallet_balance < v_total then
    raise exception 'Số dư ví không đủ. Cần %, hiện có % VND',v_total,v_wallet_balance;
  end if;

  for v_row in
    select (e.value->>'product_id')::uuid as product_id,
           sum((e.value->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as e(value)
    group by (e.value->>'product_id')::uuid
    order by (e.value->>'product_id')::uuid
  loop
    update public.products set stock=stock-v_row.quantity
    where id=v_row.product_id and active=true and stock>=v_row.quantity;
    if not found then raise exception 'Tồn kho vừa thay đổi. Vui lòng tải lại giỏ hàng'; end if;
  end loop;

  insert into public.orders(user_id,total_amount,status,items)
  values(v_user_id,v_total,'paid',v_items) returning id into v_order_id;

  -- Đánh dấu đúng các key đã gắn vào đơn hàng là đã bán.
  for v_row in select value from jsonb_array_elements(v_items)
  loop
    update public.product_keys
       set status='sold',order_id=v_order_id,user_id=v_user_id,sold_at=now()
     where id in (select jsonb_array_elements_text(v_row.value->'key_ids_internal')::uuid);
  end loop;
  -- Không lưu ID nội bộ trong JSON đơn hàng; khách chỉ thấy key đã giao.
  update public.orders set items=(
    select coalesce(jsonb_agg(value - 'key_ids_internal'),'[]'::jsonb)
    from jsonb_array_elements(v_items)
  ) where id=v_order_id;

  update public.wallets set balance=balance-v_total,updated_at=now() where user_id=v_user_id;
  if v_total>0 then
    insert into public.wallet_transactions(user_id,amount,type,note)
    values(v_user_id,-v_total,'purchase','Thanh toán đơn hàng #'||v_order_id);
  end if;
  return jsonb_build_object('order_id',v_order_id,'total_amount',v_total,
    'balance',v_wallet_balance-v_total,'status','paid');
end;
$$;

-- Khách không thể tự tạo đơn hoặc đọc kho key. Key chỉ xuất hiện trong items của đơn hàng chính chủ.
drop policy if exists "customer create own orders" on public.orders;
revoke insert on public.orders from anon,authenticated;
revoke all on function public.checkout_with_wallet(jsonb) from public,anon;
grant execute on function public.checkout_with_wallet(jsonb) to authenticated;
