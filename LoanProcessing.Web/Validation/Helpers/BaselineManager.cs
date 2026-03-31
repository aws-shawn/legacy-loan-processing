using System;
using System.Data;
using System.IO;
using Newtonsoft.Json;
using LoanProcessing.Web.Validation.Tests;

namespace LoanProcessing.Web.Validation.Helpers
{
    /// <summary>
    /// Manages baseline snapshot capture, saving, and loading for data integrity
    /// comparison across modernization stages. The baseline is stored as a JSON
    /// file in the App_Data folder.
    /// </summary>
    public static class BaselineManager
    {
        private static readonly string[] Tables = new[]
        {
            "Customers",
            "LoanApplications",
            "LoanDecisions",
            "PaymentSchedules",
            "InterestRates"
        };

        /// <summary>
        /// Captures a baseline snapshot by querying row counts for all 5 tables
        /// and retrieving sample customer data (ID=1) from the database.
        /// </summary>
        public static BaselineSnapshot CaptureBaseline(DatabaseHelper db)
        {
            if (db == null)
            {
                throw new ArgumentNullException("db");
            }

            var snapshot = new BaselineSnapshot
            {
                RowCounts = new System.Collections.Generic.Dictionary<string, int>()
            };

            // Capture row counts for all tables
            foreach (var table in Tables)
            {
                snapshot.RowCounts[table] = db.GetRowCount(table);
            }

            // Capture sample customer (ID=1)
            snapshot.SampleCustomer = CaptureSampleCustomer(db, 1);

            return snapshot;
        }

        /// <summary>
        /// Serializes the baseline snapshot to JSON and saves it to the specified file path.
        /// Creates the directory if it does not exist.
        /// </summary>
        public static void SaveBaseline(BaselineSnapshot snapshot, string filePath)
        {
            if (snapshot == null)
            {
                throw new ArgumentNullException("snapshot");
            }
            if (string.IsNullOrWhiteSpace(filePath))
            {
                throw new ArgumentException("File path cannot be null or empty.", "filePath");
            }

            string directory = Path.GetDirectoryName(filePath);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }

            string json = JsonConvert.SerializeObject(snapshot, Formatting.Indented);
            File.WriteAllText(filePath, json);
        }

        /// <summary>
        /// Loads a baseline snapshot from the specified JSON file.
        /// Returns null if the file does not exist.
        /// </summary>
        public static BaselineSnapshot LoadBaseline(string filePath)
        {
            if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath))
            {
                return null;
            }

            try
            {
                string json = File.ReadAllText(filePath);
                return JsonConvert.DeserializeObject<BaselineSnapshot>(json);
            }
            catch (Exception)
            {
                // If the file is corrupt or unreadable, treat as no baseline
                return null;
            }
        }

        /// <summary>
        /// Returns the default baseline file path.
        /// Uses the VALIDATION_BASELINE_PATH environment variable if set,
        /// otherwise falls back to App_Data/validation-baseline.json relative
        /// to the application's base directory.
        ///
        /// On containers or Linux, set VALIDATION_BASELINE_PATH to a writable
        /// location (e.g., /tmp/validation-baseline.json or a mounted volume).
        /// </summary>
        public static string GetBaselineFilePath()
        {
            // Allow override via environment variable for containers / Linux
            string envPath = Environment.GetEnvironmentVariable("VALIDATION_BASELINE_PATH");
            if (!string.IsNullOrWhiteSpace(envPath))
            {
                return envPath;
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            return Path.Combine(baseDir, "App_Data", "validation-baseline.json");
        }

        /// <summary>
        /// Retrieves sample customer data for the given customer ID.
        /// Returns null if the customer is not found.
        /// </summary>
        private static SampleCustomerData CaptureSampleCustomer(DatabaseHelper db, int customerId)
        {
            try
            {
                string idCol = db.MapColumnName("CustomerId");
                string firstNameCol = db.MapColumnName("FirstName");
                string lastNameCol = db.MapColumnName("LastName");
                string creditScoreCol = db.MapColumnName("CreditScore");
                string annualIncomeCol = db.MapColumnName("AnnualIncome");
                string table = db.MapTableName("Customers");

                string sql = string.Format(
                    "SELECT {0}, {1}, {2}, {3} FROM dbo.{4} WHERE {5} = @customerId",
                    firstNameCol, lastNameCol, creditScoreCol, annualIncomeCol, table, idCol);

                DataTable dt = db.ExecuteQuery(sql, ("@customerId", customerId));

                if (dt.Rows.Count == 0)
                {
                    return null;
                }

                DataRow row = dt.Rows[0];
                return new SampleCustomerData
                {
                    CustomerId = customerId,
                    FirstName = row[firstNameCol].ToString(),
                    LastName = row[lastNameCol].ToString(),
                    CreditScore = Convert.ToInt32(row[creditScoreCol]),
                    AnnualIncome = Convert.ToDecimal(row[annualIncomeCol])
                };
            }
            catch (Exception)
            {
                // If we can't capture the sample customer, return null
                return null;
            }
        }
    }
}
