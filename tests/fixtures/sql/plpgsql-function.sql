-- A function body starts with BEGIN on its own line; that is not transaction
-- control and must not be refused.
CREATE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.created_at := now();
  RETURN NEW;
END
$$;
