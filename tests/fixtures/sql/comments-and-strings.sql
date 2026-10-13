-- DELETE FROM app.customers;  (a comment, not a statement)
/* DROP TABLE app.orders;
   TRUNCATE app.customers; */
COMMENT ON TABLE app.customers IS 'never run DELETE or DROP TABLE on this; it''s audited';
