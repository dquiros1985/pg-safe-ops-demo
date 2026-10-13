CREATE TABLE app.customers (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      text        NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
