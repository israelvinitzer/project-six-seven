import os
import psycopg

DB_HOST = "10.0.0.20"
DB_PORT = 30432
DB_NAME = "app"
DB_USER = "app"
DB_PASSWORD = os.environ["DB_PASSWORD"]

try:
    with psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    ) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
            result = cur.fetchone()

            if result != (1,):
                raise RuntimeError(f"Unexpected query result: {result}")

            print("PostgreSQL connection successful: SELECT 1 returned 1")

except Exception as e:
    print(f"PostgreSQL validation failed: {e}")
    raise