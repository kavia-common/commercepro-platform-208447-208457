#!/bin/bash
set -euo pipefail

# Idempotent schema+seed initializer for the ecommerce database.
# IMPORTANT: Per container rules, this runs ONE SQL STATEMENT per psql call.

CONN_STR="$(cat db_connection.txt)"

run() {
  psql "${CONN_STR}" -c "$1"
}

echo "Applying extensions..."
run "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
run "CREATE EXTENSION IF NOT EXISTS citext;"

echo "Creating tables..."
run "CREATE TABLE IF NOT EXISTS roles (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL UNIQUE, description TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email CITEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, first_name TEXT, last_name TEXT, phone TEXT, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_login_at TIMESTAMPTZ);"
run "CREATE TABLE IF NOT EXISTS user_roles (user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (user_id, role_id));"

run "CREATE TABLE IF NOT EXISTS categories (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL UNIQUE, slug TEXT NOT NULL UNIQUE, description TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE TABLE IF NOT EXISTS products (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), category_id UUID REFERENCES categories(id) ON DELETE SET NULL, name TEXT NOT NULL, slug TEXT NOT NULL UNIQUE, description TEXT, price_cents INTEGER NOT NULL CHECK (price_cents >= 0), currency_code CHAR(3) NOT NULL DEFAULT 'USD', sku TEXT UNIQUE, image_url TEXT, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE INDEX IF NOT EXISTS idx_products_category_id ON products(category_id);"
run "CREATE INDEX IF NOT EXISTS idx_products_is_active ON products(is_active);"

run "CREATE TABLE IF NOT EXISTS inventory (product_id UUID PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE, quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0), reserved INTEGER NOT NULL DEFAULT 0 CHECK (reserved >= 0), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run "CREATE TABLE IF NOT EXISTS carts (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE TABLE IF NOT EXISTS cart_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), cart_id UUID NOT NULL REFERENCES carts(id) ON DELETE CASCADE, product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT, quantity INTEGER NOT NULL CHECK (quantity > 0), unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents >= 0), currency_code CHAR(3) NOT NULL DEFAULT 'USD', created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (cart_id, product_id));"
run "CREATE INDEX IF NOT EXISTS idx_cart_items_cart_id ON cart_items(cart_id);"

run "CREATE TABLE IF NOT EXISTS orders (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID REFERENCES users(id) ON DELETE SET NULL, status TEXT NOT NULL CHECK (status IN ('pending','paid','shipped','completed','cancelled','refunded')), subtotal_cents INTEGER NOT NULL CHECK (subtotal_cents >= 0), tax_cents INTEGER NOT NULL DEFAULT 0 CHECK (tax_cents >= 0), shipping_cents INTEGER NOT NULL DEFAULT 0 CHECK (shipping_cents >= 0), total_cents INTEGER NOT NULL CHECK (total_cents >= 0), currency_code CHAR(3) NOT NULL DEFAULT 'USD', payment_provider TEXT, payment_reference TEXT, shipping_name TEXT, shipping_address1 TEXT, shipping_address2 TEXT, shipping_city TEXT, shipping_state TEXT, shipping_postal_code TEXT, shipping_country TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);"
run "CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);"

run "CREATE TABLE IF NOT EXISTS order_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, product_id UUID REFERENCES products(id) ON DELETE SET NULL, product_name TEXT NOT NULL, sku TEXT, quantity INTEGER NOT NULL CHECK (quantity > 0), unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents >= 0), currency_code CHAR(3) NOT NULL DEFAULT 'USD', line_total_cents INTEGER NOT NULL CHECK (line_total_cents >= 0), created_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run "CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);"

run "CREATE TABLE IF NOT EXISTS reviews (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE, user_id UUID REFERENCES users(id) ON DELETE SET NULL, rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5), title TEXT, body TEXT, is_approved BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (product_id, user_id));"
run "CREATE INDEX IF NOT EXISTS idx_reviews_product_id ON reviews(product_id);"
run "CREATE INDEX IF NOT EXISTS idx_reviews_is_approved ON reviews(is_approved);"

echo "Creating updated_at trigger function..."
# Use single quotes to prevent shell expansion of $$.
psql "${CONN_STR}" -c 'CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;'

echo "Recreating triggers (idempotent)..."
run "DROP TRIGGER IF EXISTS trg_users_updated_at ON users;"
run "DROP TRIGGER IF EXISTS trg_categories_updated_at ON categories;"
run "DROP TRIGGER IF EXISTS trg_products_updated_at ON products;"
run "DROP TRIGGER IF EXISTS trg_carts_updated_at ON carts;"
run "DROP TRIGGER IF EXISTS trg_cart_items_updated_at ON cart_items;"
run "DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;"
run "DROP TRIGGER IF EXISTS trg_reviews_updated_at ON reviews;"

run "CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_categories_updated_at BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_carts_updated_at BEFORE UPDATE ON carts FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_cart_items_updated_at BEFORE UPDATE ON cart_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();"
run "CREATE TRIGGER trg_reviews_updated_at BEFORE UPDATE ON reviews FOR EACH ROW EXECUTE FUNCTION set_updated_at();"

echo "Seeding roles..."
run "INSERT INTO roles (name, description) VALUES ('admin','Platform administrator'),('customer','Standard customer') ON CONFLICT (name) DO NOTHING;"

echo "Seeding admin user..."
run "INSERT INTO users (email, password_hash, first_name, last_name, is_active) VALUES ('admin@example.com', crypt('admin123', gen_salt('bf')), 'Admin', 'User', TRUE) ON CONFLICT (email) DO NOTHING;"
run "INSERT INTO user_roles (user_id, role_id) SELECT u.id, r.id FROM users u, roles r WHERE u.email='admin@example.com' AND r.name='admin' ON CONFLICT DO NOTHING;"

echo "Seeding categories..."
run "INSERT INTO categories (name, slug, description) VALUES ('Electronics','electronics','Phones, computers, audio, and accessories'),('Home & Kitchen','home-kitchen','Appliances, cookware, and home essentials'),('Clothing','clothing','Apparel for all seasons'),('Books','books','Fiction, non-fiction, and educational') ON CONFLICT (slug) DO NOTHING;"

echo "Seeding products..."
run "INSERT INTO products (category_id, name, slug, description, price_cents, currency_code, sku, image_url, is_active) VALUES ((SELECT id FROM categories WHERE slug='electronics'), 'Retro Wireless Headphones', 'retro-wireless-headphones', 'Over-ear wireless headphones with retro styling and modern sound.', 7999, 'USD', 'EL-HEAD-RETRO-001', 'https://picsum.photos/seed/retroheadphones/800/600', TRUE) ON CONFLICT (slug) DO NOTHING;"
run "INSERT INTO products (category_id, name, slug, description, price_cents, currency_code, sku, image_url, is_active) VALUES ((SELECT id FROM categories WHERE slug='electronics'), 'Classic Mechanical Keyboard', 'classic-mechanical-keyboard', 'Tactile mechanical keyboard with classic beige keycaps.', 12999, 'USD', 'EL-KBD-CLASSIC-001', 'https://picsum.photos/seed/classickeyboard/800/600', TRUE) ON CONFLICT (slug) DO NOTHING;"
run "INSERT INTO products (category_id, name, slug, description, price_cents, currency_code, sku, image_url, is_active) VALUES ((SELECT id FROM categories WHERE slug='home-kitchen'), 'Enamel Coffee Mug Set', 'enamel-coffee-mug-set', 'Set of 2 durable enamel mugs—perfect for home or camping.', 2499, 'USD', 'HK-MUG-ENAMEL-002', 'https://picsum.photos/seed/enamelmug/800/600', TRUE) ON CONFLICT (slug) DO NOTHING;"
run "INSERT INTO products (category_id, name, slug, description, price_cents, currency_code, sku, image_url, is_active) VALUES ((SELECT id FROM categories WHERE slug='clothing'), 'Retro Logo T-Shirt', 'retro-logo-tshirt', 'Soft cotton t-shirt with a vintage-inspired logo print.', 1999, 'USD', 'CL-TSHIRT-RETRO-001', 'https://picsum.photos/seed/retrotshirt/800/600', TRUE) ON CONFLICT (slug) DO NOTHING;"
run "INSERT INTO products (category_id, name, slug, description, price_cents, currency_code, sku, image_url, is_active) VALUES ((SELECT id FROM categories WHERE slug='books'), 'Build an E-Commerce App (Book)', 'build-ecommerce-app-book', 'A practical guide to building modern fullstack commerce apps.', 3499, 'USD', 'BK-ECOMM-001', 'https://picsum.photos/seed/ecommercebook/800/600', TRUE) ON CONFLICT (slug) DO NOTHING;"

echo "Seeding inventory..."
run "INSERT INTO inventory (product_id, quantity, reserved) SELECT id, 25, 0 FROM products WHERE slug='retro-wireless-headphones' ON CONFLICT (product_id) DO NOTHING;"
run "INSERT INTO inventory (product_id, quantity, reserved) SELECT id, 40, 0 FROM products WHERE slug='classic-mechanical-keyboard' ON CONFLICT (product_id) DO NOTHING;"
run "INSERT INTO inventory (product_id, quantity, reserved) SELECT id, 80, 0 FROM products WHERE slug='enamel-coffee-mug-set' ON CONFLICT (product_id) DO NOTHING;"
run "INSERT INTO inventory (product_id, quantity, reserved) SELECT id, 120, 0 FROM products WHERE slug='retro-logo-tshirt' ON CONFLICT (product_id) DO NOTHING;"
run "INSERT INTO inventory (product_id, quantity, reserved) SELECT id, 60, 0 FROM products WHERE slug='build-ecommerce-app-book' ON CONFLICT (product_id) DO NOTHING;"

echo "Done. Current row counts:"
run "SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM roles) AS roles, (SELECT count(*) FROM categories) AS categories, (SELECT count(*) FROM products) AS products, (SELECT count(*) FROM inventory) AS inventory;"
