# HOÀNG HẢI VNTD — Digital Store

## Included
- Mobile-first storefront, search, category and sorting.
- Customer signup/login using Supabase Auth.
- Product administration (create/edit/hide), SKU and stock fields.
- Customer order creation and order status management.
- Supabase PostgreSQL schema and Row Level Security policies.

## 1. Create the online database
1. Create a project at https://supabase.com/.
2. Open SQL Editor and run `supabase/schema.sql`.
3. In Authentication settings, enable Email login and configure email confirmation.
4. In Project Settings → API, copy Project URL and anon/public key.
5. In `index.html`, replace `YOUR_SUPABASE_PROJECT_URL` and `YOUR_SUPABASE_ANON_KEY`.
6. Create your customer account through the website.
7. In Supabase SQL Editor, promote your own account to admin:
   `update public.profiles set role='admin' where email='YOUR_ADMIN_EMAIL';`
   Replace the email. Never make this update available to public visitors.

## 2. Publish the website
Upload `index.html` to a static host such as Netlify, Vercel or Cloudflare Pages. Use HTTPS. You can also test locally by opening the file, but Supabase Auth redirect URLs must include your deployed domain in Supabase Authentication → URL Configuration.

## 3. Payments — important
The project deliberately does NOT pretend to take real payments. Orders are created as `pending_payment`. To accept real payments, choose a provider (VNPay, MoMo, ZaloPay, Stripe, etc.) and complete its merchant onboarding. Implement payment creation and signed webhook verification on a trusted server/Edge Function. Never put merchant secret keys or Supabase service_role keys in browser code. Never mark an order paid based only on a browser redirect. Payment credentials and merchant account are required before this can be activated.

## 4. Production checklist
- Configure Supabase Auth redirect URLs and email templates.
- Test RLS using separate customer and admin accounts.
- Add server-side stock reservation/decrement in a database transaction to prevent overselling.
- Add payment provider backend and verify webhook signatures.
- Add customer support details, terms, privacy policy, refund/delivery policy.
- Add backups, monitoring, rate limits and anti-abuse controls.
- Use only digital goods and services you own or are authorized to distribute.

## Current limitation
The demo seed products are examples. If Supabase is not configured, the shop displays preview products but account, database, admin and order functions will not operate online.
