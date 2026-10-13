SELECT 'CREATE DATABASE "tracklite" OWNER "tracklite"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'tracklite')\gexec
REVOKE CONNECT ON DATABASE "tracklite" FROM PUBLIC;
GRANT CONNECT ON DATABASE "tracklite" TO "tracklite";
