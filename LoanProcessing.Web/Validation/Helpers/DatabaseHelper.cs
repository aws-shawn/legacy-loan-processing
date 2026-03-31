using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using Npgsql;

namespace LoanProcessing.Web.Validation.Helpers
{
    /// <summary>
    /// Database helper that auto-detects SQL Server vs PostgreSQL from the connection string
    /// and provides a unified query interface. Handles table/column name mapping between
    /// PascalCase (SQL Server) and snake_case (PostgreSQL after SCT migration).
    /// </summary>
    public class DatabaseHelper : IDisposable
    {
        private readonly string _connectionString;
        private const int CommandTimeoutSeconds = 30;
        private bool _disposed;

        // Table name mapping: logical (PascalCase) → PostgreSQL (snake_case)
        private static readonly Dictionary<string, string> TableNameMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "Customers", "customers" },
            { "LoanApplications", "loan_applications" },
            { "LoanDecisions", "loan_decisions" },
            { "PaymentSchedules", "payment_schedules" },
            { "InterestRates", "interest_rates" }
        };

        // Column name mapping: logical (PascalCase) → PostgreSQL (snake_case)
        private static readonly Dictionary<string, string> ColumnNameMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "CustomerId", "customer_id" },
            { "CreditScore", "credit_score" },
            { "AnnualIncome", "annual_income" },
            { "FirstName", "first_name" },
            { "LastName", "last_name" },
            { "DateOfBirth", "date_of_birth" },
            { "SSN", "ssn" },
            { "Email", "email" },
            { "Phone", "phone" },
            { "Address", "address" },
            { "LoanApplicationId", "loan_application_id" },
            { "LoanType", "loan_type" },
            { "LoanAmount", "loan_amount" },
            { "LoanTerm", "loan_term" },
            { "ApplicationDate", "application_date" },
            { "Status", "status" },
            { "LoanDecisionId", "loan_decision_id" },
            { "Decision", "decision" },
            { "RiskScore", "risk_score" },
            { "DecisionDate", "decision_date" },
            { "DebtToIncomeRatio", "debt_to_income_ratio" },
            { "Notes", "notes" },
            { "PaymentScheduleId", "payment_schedule_id" },
            { "PaymentNumber", "payment_number" },
            { "PaymentDate", "payment_date" },
            { "PaymentAmount", "payment_amount" },
            { "Principal", "principal" },
            { "Interest", "interest" },
            { "RemainingBalance", "remaining_balance" },
            { "InterestRateId", "interest_rate_id" },
            { "Rate", "rate" },
            { "EffectiveDate", "effective_date" },
            { "Description", "description" }
        };

        /// <summary>
        /// Creates a new DatabaseHelper. Auto-detects whether the connection string
        /// points to SQL Server or PostgreSQL by checking for "Host=" in the string.
        /// </summary>
        public DatabaseHelper(string connectionString)
        {
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new ArgumentException("Connection string cannot be null or empty.", "connectionString");
            }

            _connectionString = connectionString;
            IsPostgreSQL = connectionString.IndexOf("Host=", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        /// <summary>
        /// True if the connection targets PostgreSQL (Aurora), false for SQL Server.
        /// </summary>
        public bool IsPostgreSQL { get; private set; }

        /// <summary>
        /// Maps a logical table name (PascalCase) to the correct database table name.
        /// SQL Server uses PascalCase; PostgreSQL uses snake_case after SCT migration.
        /// </summary>
        public string MapTableName(string logicalName)
        {
            if (string.IsNullOrWhiteSpace(logicalName))
            {
                return logicalName;
            }

            if (IsPostgreSQL && TableNameMap.TryGetValue(logicalName, out string pgName))
            {
                return pgName;
            }

            // SQL Server: return as-is (PascalCase)
            return logicalName;
        }

        /// <summary>
        /// Maps a logical column name (PascalCase) to the correct database column name.
        /// SQL Server uses PascalCase; PostgreSQL uses snake_case after SCT migration.
        /// </summary>
        public string MapColumnName(string logicalName)
        {
            if (string.IsNullOrWhiteSpace(logicalName))
            {
                return logicalName;
            }

            if (IsPostgreSQL && ColumnNameMap.TryGetValue(logicalName, out string pgName))
            {
                return pgName;
            }

            // SQL Server: return as-is (PascalCase)
            return logicalName;
        }

        /// <summary>
        /// Returns the row count for the given table.
        /// The table name is a logical name (e.g., "Customers") and will be mapped automatically.
        /// </summary>
        public int GetRowCount(string tableName)
        {
            string mappedTable = MapTableName(tableName);
            string schema = IsPostgreSQL ? "dbo" : "dbo";
            string sql = string.Format("SELECT COUNT(*) FROM {0}.{1}", schema, mappedTable);

            try
            {
                return ExecuteScalar<int>(sql);
            }
            catch (SqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Could not count rows in table '{0}'. SQL Server error: {1}", tableName, GetFriendlySqlServerMessage(ex)), ex);
            }
            catch (NpgsqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Could not count rows in table '{0}'. PostgreSQL error: {1}", tableName, GetFriendlyPostgreSQLMessage(ex)), ex);
            }
        }

        /// <summary>
        /// Executes a SQL query and returns the results as a DataTable.
        /// Use parameterized queries to avoid SQL injection.
        /// </summary>
        public DataTable ExecuteQuery(string sql, params (string name, object value)[] parameters)
        {
            var dataTable = new DataTable();

            try
            {
                if (IsPostgreSQL)
                {
                    using (var connection = new NpgsqlConnection(_connectionString))
                    {
                        connection.Open();
                        using (var command = new NpgsqlCommand(sql, connection))
                        {
                            command.CommandTimeout = CommandTimeoutSeconds;
                            AddNpgsqlParameters(command, parameters);
                            using (var adapter = new NpgsqlDataAdapter(command))
                            {
                                adapter.Fill(dataTable);
                            }
                        }
                    }
                }
                else
                {
                    using (var connection = new SqlConnection(_connectionString))
                    {
                        connection.Open();
                        using (var command = new SqlCommand(sql, connection))
                        {
                            command.CommandTimeout = CommandTimeoutSeconds;
                            AddSqlParameters(command, parameters);
                            using (var adapter = new SqlDataAdapter(command))
                            {
                                adapter.Fill(dataTable);
                            }
                        }
                    }
                }
            }
            catch (SqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Query failed. SQL Server error: {0}", GetFriendlySqlServerMessage(ex)), ex);
            }
            catch (NpgsqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Query failed. PostgreSQL error: {0}", GetFriendlyPostgreSQLMessage(ex)), ex);
            }

            return dataTable;
        }

        /// <summary>
        /// Checks whether a constraint exists on the specified table.
        /// Works with primary keys, foreign keys, unique constraints, and check constraints.
        /// </summary>
        public bool ConstraintExists(string constraintName, string tableName)
        {
            string sql;
            string mappedTable = MapTableName(tableName);

            try
            {
                if (IsPostgreSQL)
                {
                    // PostgreSQL: check information_schema and pg_constraint
                    sql = @"SELECT COUNT(*) FROM (
                        SELECT constraint_name FROM information_schema.table_constraints
                        WHERE table_schema = 'dbo' AND LOWER(table_name) = LOWER(@tableName)
                          AND LOWER(constraint_name) = LOWER(@constraintName)
                        UNION
                        SELECT conname AS constraint_name FROM pg_constraint c
                        JOIN pg_namespace n ON n.oid = c.connamespace
                        WHERE n.nspname = 'dbo' AND LOWER(conname) = LOWER(@constraintName)
                    ) AS constraints";

                    return ExecuteScalar<long>(sql,
                        ("@tableName", mappedTable),
                        ("@constraintName", constraintName)) > 0;
                }
                else
                {
                    // SQL Server: check sys.objects and sys.check_constraints
                    sql = @"SELECT COUNT(*) FROM (
                        SELECT name FROM sys.objects
                        WHERE type IN ('PK','UQ','F') AND parent_object_id = OBJECT_ID(@fullTableName)
                          AND name = @constraintName
                        UNION
                        SELECT cc.name FROM sys.check_constraints cc
                        WHERE cc.parent_object_id = OBJECT_ID(@fullTableName)
                          AND cc.name = @constraintName
                    ) AS constraints";

                    string fullTableName = string.Format("dbo.{0}", mappedTable);
                    return ExecuteScalar<int>(sql,
                        ("@fullTableName", fullTableName),
                        ("@constraintName", constraintName)) > 0;
                }
            }
            catch (SqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Could not check constraint '{0}' on table '{1}'. SQL Server error: {2}",
                        constraintName, tableName, GetFriendlySqlServerMessage(ex)), ex);
            }
            catch (NpgsqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Could not check constraint '{0}' on table '{1}'. PostgreSQL error: {2}",
                        constraintName, tableName, GetFriendlyPostgreSQLMessage(ex)), ex);
            }
        }

        /// <summary>
        /// Executes a non-query SQL statement (INSERT, UPDATE, DELETE).
        /// Returns the number of rows affected.
        /// </summary>
        public int ExecuteNonQuery(string sql, params (string name, object value)[] parameters)
        {
            if (IsPostgreSQL)
            {
                using (var connection = new NpgsqlConnection(_connectionString))
                {
                    connection.Open();
                    using (var command = new NpgsqlCommand(sql, connection))
                    {
                        command.CommandTimeout = CommandTimeoutSeconds;
                        AddNpgsqlParameters(command, parameters);
                        return command.ExecuteNonQuery();
                    }
                }
            }
            else
            {
                using (var connection = new SqlConnection(_connectionString))
                {
                    connection.Open();
                    using (var command = new SqlCommand(sql, connection))
                    {
                        command.CommandTimeout = CommandTimeoutSeconds;
                        AddSqlParameters(command, parameters);
                        return command.ExecuteNonQuery();
                    }
                }
            }
        }

        /// <summary>
        /// Executes a scalar query and returns the result cast to the specified type.
        /// </summary>
        public T ExecuteScalar<T>(string sql, params (string name, object value)[] parameters)
        {
            try
            {
                object result;

                if (IsPostgreSQL)
                {
                    using (var connection = new NpgsqlConnection(_connectionString))
                    {
                        connection.Open();
                        using (var command = new NpgsqlCommand(sql, connection))
                        {
                            command.CommandTimeout = CommandTimeoutSeconds;
                            AddNpgsqlParameters(command, parameters);
                            result = command.ExecuteScalar();
                        }
                    }
                }
                else
                {
                    using (var connection = new SqlConnection(_connectionString))
                    {
                        connection.Open();
                        using (var command = new SqlCommand(sql, connection))
                        {
                            command.CommandTimeout = CommandTimeoutSeconds;
                            AddSqlParameters(command, parameters);
                            result = command.ExecuteScalar();
                        }
                    }
                }

                if (result == null || result == DBNull.Value)
                {
                    return default(T);
                }

                return (T)Convert.ChangeType(result, typeof(T));
            }
            catch (SqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Scalar query failed. SQL Server error: {0}", GetFriendlySqlServerMessage(ex)), ex);
            }
            catch (NpgsqlException ex)
            {
                throw new InvalidOperationException(
                    string.Format("Scalar query failed. PostgreSQL error: {0}", GetFriendlyPostgreSQLMessage(ex)), ex);
            }
        }

        /// <summary>
        /// Adds parameters to a SqlCommand.
        /// </summary>
        private static void AddSqlParameters(SqlCommand command, (string name, object value)[] parameters)
        {
            if (parameters == null) return;

            foreach (var param in parameters)
            {
                command.Parameters.AddWithValue(param.name, param.value ?? DBNull.Value);
            }
        }

        /// <summary>
        /// Adds parameters to an NpgsqlCommand.
        /// </summary>
        private static void AddNpgsqlParameters(NpgsqlCommand command, (string name, object value)[] parameters)
        {
            if (parameters == null) return;

            foreach (var param in parameters)
            {
                command.Parameters.AddWithValue(param.name, param.value ?? DBNull.Value);
            }
        }

        /// <summary>
        /// Maps common SQL Server error codes to human-readable messages.
        /// </summary>
        private static string GetFriendlySqlServerMessage(SqlException ex)
        {
            switch (ex.Number)
            {
                case 4060:
                    return "The database was not found. Check that the database name in the connection string is correct.";
                case 18456:
                    return "Login failed. Check the username and password in the connection string.";
                case 2:
                case 53:
                    return "Cannot reach the SQL Server. Check that the server is running and the hostname is correct.";
                case 208:
                    return "The table or view was not found. The database schema may not have been created yet.";
                default:
                    return ex.Message;
            }
        }

        /// <summary>
        /// Maps common PostgreSQL error states to human-readable messages.
        /// </summary>
        private static string GetFriendlyPostgreSQLMessage(NpgsqlException ex)
        {
            // Npgsql doesn't expose SqlState directly on all versions,
            // so we check the message for common patterns as a fallback.
            var message = ex.Message ?? string.Empty;

            if (message.IndexOf("28P01", StringComparison.OrdinalIgnoreCase) >= 0
                || message.IndexOf("password authentication failed", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "Password authentication failed. Check the username and password in the connection string.";
            }

            if (message.IndexOf("3D000", StringComparison.OrdinalIgnoreCase) >= 0
                || message.IndexOf("does not exist", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "The database does not exist. Check that the database name in the connection string is correct.";
            }

            if (message.IndexOf("could not connect", StringComparison.OrdinalIgnoreCase) >= 0
                || message.IndexOf("connection refused", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "Cannot reach the PostgreSQL server. Check that the server is running and the hostname is correct.";
            }

            if (message.IndexOf("relation", StringComparison.OrdinalIgnoreCase) >= 0
                && message.IndexOf("does not exist", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "The table was not found. The database schema may not have been migrated yet.";
            }

            return ex.Message;
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (!_disposed)
            {
                // No persistent connections to dispose — connections are opened/closed per operation.
                // This pattern is here for future extensibility and to satisfy IDisposable contract.
                _disposed = true;
            }
        }
    }
}
