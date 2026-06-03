import java.sql.*;

public class MariaDBTest {
    public static void main(String[] args) {
        String host = System.getenv().getOrDefault("DB_HOST", "mariadb");
        String user = System.getenv("DB_USER");
        String password = System.getenv("DB_PASSWORD");
        String database = System.getenv().getOrDefault("DB_DATABASE", "");
        String query = System.getenv().getOrDefault("DB_QUERY", "SELECT 1");

        String jdbcParams = System.getenv().getOrDefault("DB_JDBC_PARAMS", "useSsl=false");
        String url = "jdbc:mariadb://" + host + ":3306/" + database + "?" + jdbcParams;

        try (Connection conn = DriverManager.getConnection(url, user, password);
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery(query)) {

            int colCount = rs.getMetaData().getColumnCount();
            while (rs.next()) {
                StringBuilder sb = new StringBuilder();
                for (int i = 1; i <= colCount; i++) {
                    if (i > 1) sb.append("\t");
                    sb.append(rs.getString(i));
                }
                System.out.println(sb);
            }
        } catch (SQLException e) {
            if (e.getErrorCode() == 1045) {
                System.err.println("Access denied");
            } else {
                System.err.println(e.getMessage());
            }
            System.exit(1);
        }
    }
}
