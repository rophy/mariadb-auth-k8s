package main

import (
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"fmt"
	"os"
	"strings"

	"github.com/go-sql-driver/mysql"
)

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	host := envOrDefault("DB_HOST", "mariadb")
	user := os.Getenv("DB_USER")
	password := os.Getenv("DB_PASSWORD")
	database := envOrDefault("DB_DATABASE", "")
	query := envOrDefault("DB_QUERY", "SELECT 1")
	tlsCa := os.Getenv("DB_TLS_CA")

	tlsParam := ""
	if tlsCa != "" {
		rootCertPool := x509.NewCertPool()
		pem, err := os.ReadFile(tlsCa)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to read CA: %v\n", err)
			os.Exit(1)
		}
		rootCertPool.AppendCertsFromPEM(pem)
		mysql.RegisterTLSConfig("custom", &tls.Config{RootCAs: rootCertPool})
		tlsParam = "&tls=custom"
	}

	dsn := fmt.Sprintf("%s:%s@tcp(%s:3306)/%s?allowCleartextPasswords=true%s",
		user, password, host, database, tlsParam)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	rows, err := db.Query(query)
	if err != nil {
		if strings.Contains(err.Error(), "Access denied") {
			fmt.Fprintln(os.Stderr, "Access denied")
		} else {
			fmt.Fprintf(os.Stderr, "%v\n", err)
		}
		os.Exit(1)
	}
	defer rows.Close()

	cols, _ := rows.Columns()
	vals := make([]interface{}, len(cols))
	ptrs := make([]interface{}, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	for rows.Next() {
		rows.Scan(ptrs...)
		parts := make([]string, len(vals))
		for i, v := range vals {
			parts[i] = fmt.Sprintf("%s", v)
		}
		fmt.Println(strings.Join(parts, "\t"))
	}
}
