using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using LoanProcessing.Web.Models;

namespace LoanProcessing.Web.Data
{
    /// <summary>
    /// Repository implementation for loan application data access using ADO.NET and stored procedures.
    /// Demonstrates legacy pattern with manual parameter mapping and result set handling.
    /// </summary>
    public class LoanApplicationRepository : ILoanApplicationRepository
    {
        private readonly string _connectionString;

        /// <summary>
        /// Initializes a new instance of the LoanApplicationRepository class.
        /// </summary>
        /// <param name="connectionString">The database connection string.</param>
        public LoanApplicationRepository(string connectionString)
        {
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new ArgumentNullException(nameof(connectionString));
            }

            _connectionString = connectionString;
        }

        /// <summary>
        /// Initializes a new instance of the LoanApplicationRepository class using the default connection string.
        /// </summary>
        public LoanApplicationRepository()
            : this(ConfigurationManager.ConnectionStrings["LoanProcessingConnection"].ConnectionString)
        {
        }

        /// <summary>
        /// Retrieves all loan applications.
        /// Uses direct SQL query to retrieve all applications.
        /// </summary>
        /// <returns>A collection of all loan applications.</returns>
        public IEnumerable<LoanApplication> GetAll()
        {
            var applications = new List<LoanApplication>();

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    SELECT 
                        ApplicationId,
                        ApplicationNumber,
                        CustomerId,
                        LoanType,
                        RequestedAmount,
                        TermMonths,
                        Purpose,
                        Status,
                        ApplicationDate,
                        ApprovedAmount,
                        InterestRate
                    FROM LoanApplications
                    ORDER BY ApplicationDate DESC";

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        applications.Add(MapLoanApplicationFromReader(reader));
                    }
                }
            }

            return applications;
        }

        /// <summary>
        /// Submits a new loan application to the database.
        /// Calls sp_SubmitLoanApplication stored procedure with manual parameter mapping.
        /// </summary>
        /// <param name="application">The loan application to submit.</param>
        /// <returns>The newly created application ID.</returns>
        /// <exception cref="ArgumentNullException">Thrown when application is null.</exception>
        /// <exception cref="SqlException">Thrown when database operation fails.</exception>
        public int SubmitApplication(LoanApplication application)
        {
            if (application == null)
            {
                throw new ArgumentNullException(nameof(application));
            }

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand("sp_SubmitLoanApplication", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                // Manual parameter mapping - legacy pattern
                command.Parameters.AddWithValue("@CustomerId", application.CustomerId);
                command.Parameters.AddWithValue("@LoanType", application.LoanType);
                command.Parameters.AddWithValue("@RequestedAmount", application.RequestedAmount);
                command.Parameters.AddWithValue("@TermMonths", application.TermMonths);
                command.Parameters.AddWithValue("@Purpose", application.Purpose);

                // Output parameter for the new application ID
                var outputParam = new SqlParameter("@ApplicationId", SqlDbType.Int)
                {
                    Direction = ParameterDirection.Output
                };
                command.Parameters.Add(outputParam);

                connection.Open();
                command.ExecuteNonQuery();

                return (int)outputParam.Value;
            }
        }

        /// <summary>
        /// Retrieves a loan application by its unique identifier.
        /// Uses direct SQL query to retrieve application details.
        /// </summary>
        /// <param name="applicationId">The application ID to retrieve.</param>
        /// <returns>The loan application if found; otherwise, null.</returns>
        public LoanApplication GetById(int applicationId)
        {
            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    SELECT 
                        ApplicationId,
                        ApplicationNumber,
                        CustomerId,
                        LoanType,
                        RequestedAmount,
                        TermMonths,
                        Purpose,
                        Status,
                        ApplicationDate,
                        ApprovedAmount,
                        InterestRate
                    FROM LoanApplications
                    WHERE ApplicationId = @ApplicationId";

                command.Parameters.AddWithValue("@ApplicationId", applicationId);

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        return MapLoanApplicationFromReader(reader);
                    }
                }
            }

            return null;
        }

        /// <summary>
        /// Retrieves all loan applications for a specific customer.
        /// Uses direct SQL query to retrieve customer's applications.
        /// </summary>
        /// <param name="customerId">The customer ID to retrieve applications for.</param>
        /// <returns>A collection of loan applications for the customer.</returns>
        public IEnumerable<LoanApplication> GetByCustomer(int customerId)
        {
            var applications = new List<LoanApplication>();

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    SELECT 
                        ApplicationId,
                        ApplicationNumber,
                        CustomerId,
                        LoanType,
                        RequestedAmount,
                        TermMonths,
                        Purpose,
                        Status,
                        ApplicationDate,
                        ApprovedAmount,
                        InterestRate
                    FROM LoanApplications
                    WHERE CustomerId = @CustomerId
                    ORDER BY ApplicationDate DESC";

                command.Parameters.AddWithValue("@CustomerId", customerId);

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        applications.Add(MapLoanApplicationFromReader(reader));
                    }
                }
            }

            return applications;
        }

        /// <summary>
        /// Returns the sum of ApprovedAmount for all approved applications for the given customer,
        /// excluding the specified application.
        /// </summary>
        /// <param name="customerId">The customer ID to sum approved amounts for.</param>
        /// <param name="excludeApplicationId">The application ID to exclude from the sum.</param>
        /// <returns>The total approved amount, or 0 if no approved loans exist.</returns>
        public decimal GetApprovedAmountsByCustomer(int customerId, int excludeApplicationId)
        {
            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    SELECT ISNULL(SUM(ApprovedAmount), 0)
                    FROM LoanApplications
                    WHERE CustomerId = @CustomerId
                      AND Status = 'Approved'
                      AND ApplicationId != @ExcludeApplicationId";

                command.Parameters.AddWithValue("@CustomerId", customerId);
                command.Parameters.AddWithValue("@ExcludeApplicationId", excludeApplicationId);

                connection.Open();
                var result = command.ExecuteScalar();
                return (result == DBNull.Value || result == null) ? 0m : Convert.ToDecimal(result);
            }
        }

        /// <summary>
        /// Updates the application's Status and InterestRate columns.
        /// </summary>
        /// <param name="applicationId">The application ID to update.</param>
        /// <param name="status">The new status value.</param>
        /// <param name="interestRate">The new interest rate value.</param>
        public void UpdateStatusAndRate(int applicationId, string status, decimal interestRate)
        {
            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    UPDATE LoanApplications
                    SET Status = @Status,
                        InterestRate = @InterestRate
                    WHERE ApplicationId = @ApplicationId";

                command.Parameters.AddWithValue("@ApplicationId", applicationId);
                command.Parameters.AddWithValue("@Status", status);
                command.Parameters.AddWithValue("@InterestRate", interestRate);

                connection.Open();
                command.ExecuteNonQuery();
            }
        }

        /// <summary>
        /// Maps a SqlDataReader row to a LoanApplication object.
        /// Demonstrates manual result mapping pattern common in legacy applications.
        /// </summary>
        /// <param name="reader">The SqlDataReader positioned at a loan application row.</param>
        /// <returns>A LoanApplication object populated from the reader.</returns>
        private LoanApplication MapLoanApplicationFromReader(SqlDataReader reader)
        {
            return new LoanApplication
            {
                ApplicationId = reader.GetInt32(reader.GetOrdinal("ApplicationId")),
                ApplicationNumber = reader.GetString(reader.GetOrdinal("ApplicationNumber")),
                CustomerId = reader.GetInt32(reader.GetOrdinal("CustomerId")),
                LoanType = reader.GetString(reader.GetOrdinal("LoanType")),
                RequestedAmount = reader.GetDecimal(reader.GetOrdinal("RequestedAmount")),
                TermMonths = reader.GetInt32(reader.GetOrdinal("TermMonths")),
                Purpose = reader.GetString(reader.GetOrdinal("Purpose")),
                Status = reader.GetString(reader.GetOrdinal("Status")),
                ApplicationDate = reader.GetDateTime(reader.GetOrdinal("ApplicationDate")),
                ApprovedAmount = reader.IsDBNull(reader.GetOrdinal("ApprovedAmount"))
                    ? (decimal?)null
                    : reader.GetDecimal(reader.GetOrdinal("ApprovedAmount")),
                InterestRate = reader.IsDBNull(reader.GetOrdinal("InterestRate"))
                    ? (decimal?)null
                    : reader.GetDecimal(reader.GetOrdinal("InterestRate"))
            };
        }
    }
}
