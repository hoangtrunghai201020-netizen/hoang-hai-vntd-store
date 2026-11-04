// HOÀNG HẢI VNTD STORE — Telegram bot (phương án A)
// Supabase Edge Function name: telegram-bot
// Secrets cần có: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID,
// TELEGRAM_WEBHOOK_SECRET, SHOP_URL
// Supabase tự cung cấp SUPABASE_URL và SUPABASE_ANON_KEY cho Edge Functions.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const OWNER_CHAT_ID = Deno.env.get("TELEGRAM_CHAT_ID") ?? "";
const WEBHOOK_SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const SHOP_URL = Deno.env.get("SHOP_URL") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type TelegramMessage = {
  message_id: number;
  chat: { id: number };
  from?: { id: number; username?: string; first_name?: string; last_name?: string };
  text?: string;
};

type TelegramUpdate = {
  message?: TelegramMessage;
  callback_query?: {
    id: string;
    data?: string;
    message?: { chat: { id: number }; message_id: number };
    from?: { id: number; username?: string; first_name?: string };
  };
};

function esc(value: unknown): string {
  return String(value ?? "").replace(/[&<>"]/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;",
  }[c]!));
}

async function telegram(method: string, body: Record<string, unknown>) {
  const response = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok || !result.ok) {
    console.error("Telegram API error:", result);
    throw new Error("Telegram API request failed");
  }
  return result;
}

async function send(chatId: number | string, text: string, keyboard?: unknown) {
  return await telegram("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
    ...(keyboard ? { reply_markup: keyboard } : {}),
  });
}

function menuKeyboard() {
  return {
    inline_keyboard: [
      [{ text: "🛍️ MUA SẢN PHẨM", callback_data: "products" }],
      [
        { text: "🌐 MỞ WEBSITE", url: SHOP_URL },
        { text: "💎 NẠP TIỀN", callback_data: "wallet" },
      ],
      [
        { text: "📦 ĐƠN HÀNG", callback_data: "orders" },
        { text: "🎧 HỖ TRỢ", callback_data: "support" },
      ],
    ],
  };
}

async function showProducts(chatId: number) {
  const { data, error } = await supabase
    .from("products")
    .select("name,category,price,stock,description")
    .eq("active", true)
    .gt("stock", 0)
    .order("created_at", { ascending: false })
    .limit(20);

  if (error) {
    console.error("Supabase products error:", error);
    await send(chatId, "Hiện chưa tải được danh sách sản phẩm. Bạn vui lòng mở website để xem shop.", {
      inline_keyboard: [[{ text: "🌐 MỞ WEBSITE", url: SHOP_URL }]],
    });
    return;
  }

  if (!data?.length) {
    await send(chatId, "Shop hiện chưa có sản phẩm còn hàng. Bạn có thể mở website để kiểm tra cập nhật mới nhất.", {
      inline_keyboard: [[{ text: "🌐 MỞ WEBSITE", url: SHOP_URL }]],
    });
    return;
  }

  const lines = data.map((p, i) =>
    `${i + 1}. <b>${esc(p.name)}</b>\n` +
    `   Danh mục: ${esc(p.category || "Khác")}\n` +
    `   Giá: <b>${new Intl.NumberFormat("vi-VN").format(Number(p.price) || 0)}₫</b>\n` +
    `   Còn: ${Number(p.stock) || 0}\n`
  );

  await send(chatId,
    `🛍️ <b>SẢN PHẨM ĐANG BÁN</b>\n\n${lines.join("\n")}\n` +
    `Để đăng nhập, thêm vào giỏ, thanh toán bằng Ví VND và nhận key tự động, nhấn nút bên dưới.`,
    { inline_keyboard: [[{ text: "🛒 MUA TRÊN WEBSITE", url: SHOP_URL }], [{ text: "⬅️ MENU", callback_data: "menu" }]] },
  );
}

async function handleAction(chatId: number, action: string) {
  if (action === "menu") {
    await send(chatId,
      "✨ <b>HOÀNG HẢI VNTD STORE</b>\nChào mừng bạn! Chọn chức năng bên dưới.",
      menuKeyboard(),
    );
    return;
  }

  if (action === "products") {
    await showProducts(chatId);
    return;
  }

  if (action === "wallet") {
    await send(chatId,
      "💎 <b>NẠP TIỀN VÍ VND</b>\n\n" +
      "1. Mở website và đăng nhập tài khoản.\n" +
      "2. Chọn mục Ví / Nạp tiền.\n" +
      "3. Chuyển khoản đúng số tiền và nội dung hiển thị.\n" +
      "4. Gửi yêu cầu và chờ ADMIN kiểm tra giao dịch thực tế.\n\n" +
      "Lưu ý: Shop chỉ cộng tiền sau khi xác nhận đã nhận được chuyển khoản.",
      { inline_keyboard: [[{ text: "💎 MỞ VÍ TRÊN WEBSITE", url: SHOP_URL }], [{ text: "⬅️ MENU", callback_data: "menu" }]] },
    );
    return;
  }

  if (action === "orders") {
    await send(chatId,
      "📦 <b>ĐƠN HÀNG CỦA BẠN</b>\n\n" +
      "Đăng nhập trên website bằng tài khoản đã mua để xem trạng thái đơn hàng và key đã giao.",
      { inline_keyboard: [[{ text: "📦 XEM ĐƠN HÀNG", url: SHOP_URL }], [{ text: "⬅️ MENU", callback_data: "menu" }]] },
    );
    return;
  }

  if (action === "support") {
    await send(chatId,
      "🎧 <b>HỖ TRỢ KHÁCH HÀNG</b>\n\n" +
      "Bạn hãy gửi nội dung cần hỗ trợ ngay trong cuộc trò chuyện này. Bot sẽ chuyển tin nhắn đến quản trị viên.",
      { inline_keyboard: [[{ text: "⬅️ MENU", callback_data: "menu" }]] },
    );
    return;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("HOANG HAI VNTD Telegram bot is running.", { status: 200 });
  }

  if (!BOT_TOKEN || !OWNER_CHAT_ID || !WEBHOOK_SECRET || !SHOP_URL ||
      !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    console.error("Missing required Edge Function secrets/environment.");
    return new Response("Bot configuration is incomplete.", { status: 500 });
  }

  const suppliedSecret = req.headers.get("x-telegram-bot-api-secret-token") ?? "";
  if (suppliedSecret !== WEBHOOK_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }

  let update: TelegramUpdate;
  try {
    update = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  try {
    if (update.callback_query) {
      const query = update.callback_query;
      await telegram("answerCallbackQuery", { callback_query_id: query.id });
      if (query.message?.chat?.id && query.data) {
        await handleAction(query.message.chat.id, query.data);
      }
      return new Response("ok", { status: 200 });
    }

    const message = update.message;
    if (!message?.chat?.id || !message.text) {
      return new Response("ok", { status: 200 });
    }

    const chatId = message.chat.id;
    const text = message.text.trim();

    if (text === "/start" || text === "/menu") {
      await handleAction(chatId, "menu");
      return new Response("ok", { status: 200 });
    }
    if (text === "/products" || text === "🛍️ Mua sản phẩm") {
      await handleAction(chatId, "products");
      return new Response("ok", { status: 200 });
    }
    if (text === "/wallet") {
      await handleAction(chatId, "wallet");
      return new Response("ok", { status: 200 });
    }
    if (text === "/orders") {
      await handleAction(chatId, "orders");
      return new Response("ok", { status: 200 });
    }
    if (text === "/help" || text === "/support") {
      await handleAction(chatId, "support");
      return new Response("ok", { status: 200 });
    }

    // Tin nhắn tự do được chuyển tới ADMIN để hỗ trợ.
    const sender = message.from;
    const senderName = [sender?.first_name, sender?.last_name].filter(Boolean).join(" ") || "Khách Telegram";
    const username = sender?.username ? `@${sender.username}` : "(không có username)";
    await send(OWNER_CHAT_ID,
      `🎧 <b>YÊU CẦU HỖ TRỢ TELEGRAM</b>\n` +
      `Khách: ${esc(senderName)} ${esc(username)}\n` +
      `Telegram ID: <code>${chatId}</code>\n\n` +
      `${esc(text)}`,
    );
    await send(chatId,
      "✅ Shop đã nhận được tin nhắn hỗ trợ. Quản trị viên sẽ phản hồi sớm nhất có thể.",
      { inline_keyboard: [[{ text: "⬅️ MENU", callback_data: "menu" }]] },
    );
  } catch (error) {
    console.error("Bot handler error:", error);
  }

  return new Response("ok", { status: 200 });
});
