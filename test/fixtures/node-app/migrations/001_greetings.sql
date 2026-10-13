-- The fixture's one migration. It can run again: every deploy migrates.
CREATE TABLE IF NOT EXISTS greetings (id integer PRIMARY KEY, text text NOT NULL);
INSERT INTO greetings (id, text) VALUES (1, 'hello') ON CONFLICT (id) DO NOTHING;
