#!/usr/bin/env python3
import os
import sys
import pymysql

host = os.environ.get("DB_HOST", "mariadb")
user = os.environ["DB_USER"]
password = os.environ["DB_PASSWORD"]
database = os.environ.get("DB_DATABASE")
query = os.environ.get("DB_QUERY", "SELECT 1")
tls_ca = os.environ.get("DB_TLS_CA")

ssl_opts = None
if tls_ca:
    ssl_opts = {"ca": tls_ca}

try:
    conn = pymysql.connect(
        host=host,
        port=3306,
        user=user,
        password=password,
        database=database,
        ssl=ssl_opts,
    )
    cursor = conn.cursor()
    cursor.execute(query)
    for row in cursor:
        print("\t".join(str(col) for col in row))
    conn.close()
except pymysql.Error as e:
    print(f"Access denied" if e.args[0] == 1045 else str(e), file=sys.stderr)
    sys.exit(1)
