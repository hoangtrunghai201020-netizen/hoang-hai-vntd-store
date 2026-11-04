-- HOÀNG HẢI VNTD — THANH TOÁN BẰNG VÍ VND
-- Chạy MỘT LẦN trong Supabase > SQL Editor > New query.
-- Giữ nguyên các bảng hiện có. RPC này tự tính giá từ products, không tin giá từ trình duyệt.

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

  -- Mỗi dòng phải có product_id UUID và quantity nguyên dương.
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

  -- Tạo ví rỗng nếu tài khoản chưa từng nạp tiền, sau đó khóa dòng ví.
  insert into public.wallets(user_id, balance)
  values (v_user_id, 0)
  on conflict (user_id) do nothing;

  select balance into v_wallet_balance
  from public.wallets
  where user_id = v_user_id
  for update;

  -- Gộp các dòng trùng sản phẩm và khóa sản phẩm theo thứ tự UUID.
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

  -- Trừ tồn kho; nếu bất kỳ bước nào lỗi, toàn bộ giao dịch tự rollback.
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
  returning id into v_order_id;

  update public.wallets
  set balance = balance - v_total,
      updated_at = now()
  where user_id = v_user_id;

  if v_total > 0 then
    insert into public.wallet_transactions(user_id, amount, type, note)
    values (v_user_id, -v_total, 'purchase',
            'Thanh toán đơn hàng #' || v_order_id);
  end if;

  return jsonb_build_object(
    'order_id', v_order_id,
    'total_amount', v_total,
    'balance', v_wallet_balance - v_total,
    'status', 'paid'
  );
end;
$$;

-- Buộc khách thanh toán đơn mới qua RPC, không được tự ghi đơn pending_payment từ trình duyệt.
drop policy if exists "customer create own orders" on public.orders;
revoke insert on public.orders from anon, authenticated;

revoke all on function public.checkout_with_wallet(jsonb) from public;
revoke all on function public.checkout_with_wallet(jsonb) from anon;
grant execute on function public.checkout_with_wallet(jsonb) to authenticated;
