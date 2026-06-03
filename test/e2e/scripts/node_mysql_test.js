const mysql = require("mysql2/promise");
const fs = require("fs");

async function main() {
  const host = process.env.DB_HOST || "mariadb";
  const user = process.env.DB_USER;
  const password = process.env.DB_PASSWORD;
  const database = process.env.DB_DATABASE || undefined;
  const query = process.env.DB_QUERY || "SELECT 1";
  const tlsCa = process.env.DB_TLS_CA;

  const opts = {
    host,
    port: 3306,
    user,
    password,
    database,
    authPlugins: {
      mysql_clear_password: () => () => Buffer.from(password + "\0"),
    },
  };

  if (tlsCa) {
    opts.ssl = { ca: fs.readFileSync(tlsCa) };
  }

  let conn;
  try {
    conn = await mysql.createConnection(opts);
    const [rows] = await conn.execute(query);
    for (const row of rows) {
      console.log(Object.values(row).join("\t"));
    }
  } catch (e) {
    if (e.code === "ER_ACCESS_DENIED_ERROR") {
      process.stderr.write("Access denied\n");
    } else {
      process.stderr.write(e.message + "\n");
    }
    process.exit(1);
  } finally {
    if (conn) await conn.end();
  }
}

main();
