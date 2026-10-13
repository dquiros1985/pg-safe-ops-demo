-- The kind of "cleanup" that empties a table when it runs against the wrong
-- database.
DELETE FROM app.customers
WHERE created_at < now() - interval '1 year';
