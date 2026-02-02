# Ecommerce Database Schema + Seed (PostgreSQL)

This container uses PostgreSQL (running on port `5000` by default via `startup.sh`).

Per container rules, the schema and seed data are applied directly using one-statement-at-a-time `psql -c` commands (no `.sql` migration files).

## Connection

Use the authoritative connection string from `db_connection.txt`:

```bash
cat db_connection.txt
# psql postgresql://appuser:dbuser123@localhost:5000/myapp
```

## Extensions enabled

- `pgcrypto` (UUID generation via `gen_random_uuid()` and password hashing via `crypt()`)
- `citext` (case-insensitive email uniqueness)

## Tables

### Auth / Users / Roles

- `roles`
  - `id UUID PK`
  - `name TEXT UNIQUE` (e.g. `admin`, `customer`)
  - `description`
  - `created_at`

- `users`
  - `id UUID PK`
  - `email CITEXT UNIQUE`
  - `password_hash TEXT` (bcrypt hash stored from `pgcrypto.crypt()`)
  - `first_name`, `last_name`, `phone`
  - `is_active BOOLEAN`
  - `created_at`, `updated_at`, `last_login_at`

- `user_roles` (many-to-many)
  - `user_id` FK -> `users(id)` (CASCADE)
  - `role_id` FK -> `roles(id)` (CASCADE)
  - `(user_id, role_id)` composite PK

### Catalog / Inventory

- `categories`
  - `id UUID PK`
  - `name TEXT UNIQUE`
  - `slug TEXT UNIQUE`
  - `description`
  - `created_at`, `updated_at`

- `products`
  - `id UUID PK`
  - `category_id` FK -> `categories(id)` (SET NULL)
  - `name`
  - `slug TEXT UNIQUE`
  - `description`
  - `price_cents INT CHECK >= 0`
  - `currency_code CHAR(3)` default `USD`
  - `sku TEXT UNIQUE`
  - `image_url`
  - `is_active BOOLEAN`
  - `created_at`, `updated_at`
  - indexes:
    - `idx_products_category_id(category_id)`
    - `idx_products_is_active(is_active)`

- `inventory`
  - `product_id UUID PK` FK -> `products(id)` (CASCADE)
  - `quantity INT CHECK >= 0`
  - `reserved INT CHECK >= 0`
  - `updated_at`

### Cart

- `carts`
  - `id UUID PK`
  - `user_id UUID UNIQUE` FK -> `users(id)` (CASCADE)  
    (enforces 1 active cart per user)
  - `created_at`, `updated_at`

- `cart_items`
  - `id UUID PK`
  - `cart_id` FK -> `carts(id)` (CASCADE)
  - `product_id` FK -> `products(id)` (RESTRICT)
  - `quantity INT CHECK > 0`
  - `unit_price_cents INT CHECK >= 0` (captured at time of add-to-cart)
  - `currency_code CHAR(3)` default `USD`
  - `created_at`, `updated_at`
  - constraint: `UNIQUE(cart_id, product_id)`
  - index:
    - `idx_cart_items_cart_id(cart_id)`

### Orders

- `orders`
  - `id UUID PK`
  - `user_id` FK -> `users(id)` (SET NULL)
  - `status TEXT CHECK IN ('pending','paid','shipped','completed','cancelled','refunded')`
  - totals:
    - `subtotal_cents`, `tax_cents`, `shipping_cents`, `total_cents` (all CHECK >= 0)
  - `currency_code CHAR(3)` default `USD`
  - payment:
    - `payment_provider`, `payment_reference`
  - shipping:
    - `shipping_name`, `shipping_address1`, `shipping_address2`, `shipping_city`,
      `shipping_state`, `shipping_postal_code`, `shipping_country`
  - `created_at`, `updated_at`
  - indexes:
    - `idx_orders_user_id(user_id)`
    - `idx_orders_status(status)`

- `order_items`
  - `id UUID PK`
  - `order_id` FK -> `orders(id)` (CASCADE)
  - `product_id` FK -> `products(id)` (SET NULL)
  - snapshot fields:
    - `product_name` (required)
    - `sku`
  - `quantity INT CHECK > 0`
  - `unit_price_cents INT CHECK >= 0`
  - `currency_code CHAR(3)` default `USD`
  - `line_total_cents INT CHECK >= 0`
  - `created_at`
  - index:
    - `idx_order_items_order_id(order_id)`

### Reviews

- `reviews`
  - `id UUID PK`
  - `product_id` FK -> `products(id)` (CASCADE)
  - `user_id` FK -> `users(id)` (SET NULL)
  - `rating SMALLINT CHECK BETWEEN 1 AND 5`
  - `title`, `body`
  - `is_approved BOOLEAN` default `TRUE`
  - `created_at`, `updated_at`
  - constraint: `UNIQUE(product_id, user_id)`
  - indexes:
    - `idx_reviews_product_id(product_id)`
    - `idx_reviews_is_approved(is_approved)`

## updated_at triggers

A shared trigger function is created:

- `set_updated_at()` (plpgsql trigger function)

And triggers are installed on:
- `users`, `categories`, `products`, `carts`, `cart_items`, `orders`, `reviews`

## Seed data

### Roles
- `admin`
- `customer`

### Initial admin user

- email: `admin@example.com`
- password: `admin123` (stored as bcrypt hash in `users.password_hash`)
- assigned role: `admin`

### Categories
- Electronics (`electronics`)
- Home & Kitchen (`home-kitchen`)
- Clothing (`clothing`)
- Books (`books`)

### Products (sample)
- Retro Wireless Headphones
- Classic Mechanical Keyboard
- Enamel Coffee Mug Set
- Retro Logo T-Shirt
- Build an E-Commerce App (Book)

### Inventory (sample)
Each seeded product gets inventory rows with non-zero quantities.

## Notes for backend/frontend integration

- Emails are stored as `CITEXT` and unique case-insensitively.
- Prices are stored as integer cents (`price_cents`, `unit_price_cents`) to avoid float issues.
- Cart items capture unit price at time of add-to-cart.
- Order items capture product name/sku snapshot for historical accuracy if product changes.
- Order status uses a strict CHECK constraint for consistent API behavior.

## Verify data counts

Example query:

```sql
SELECT
  (SELECT count(*) FROM users) AS users,
  (SELECT count(*) FROM roles) AS roles,
  (SELECT count(*) FROM categories) AS categories,
  (SELECT count(*) FROM products) AS products,
  (SELECT count(*) FROM inventory) AS inventory;
```
