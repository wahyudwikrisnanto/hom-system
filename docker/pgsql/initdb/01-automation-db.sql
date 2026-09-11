-- The automation panel keeps its suites and run history in its own database, so
-- `make fresh` on the app database never wipes the test history. Runs only when
-- the postgres volume is created; `npm run db:migrate` builds the tables.
CREATE DATABASE hom_automation OWNER hom;
