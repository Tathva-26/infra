-- Runs only on first volume init. For existing volumes, create the DB manually
-- (see README). Idempotent: safe to re-run.
SELECT 'CREATE DATABASE hackathon'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'hackathon')\gexec
