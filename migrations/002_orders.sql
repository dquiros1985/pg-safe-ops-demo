-- "ON DELETE CASCADE" is a foreign-key rule, not a DELETE statement;
-- sql-guard.sh must let this file through.
CREATE TABLE app.orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint      NOT NULL REFERENCES app.customers (id) ON DELETE CASCADE,
  total_cents integer     NOT NULL CHECK (total_cents >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX orders_customer_id_idx ON app.orders (customer_id);
