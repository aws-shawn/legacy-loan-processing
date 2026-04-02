using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using LoanProcessing.Web.Models;
using LoanProcessing.Web.Services;

namespace LoanProcessing.Web.Data
{
    /// <summary>
    /// Repository implementation for loan decision data access using ADO.NET and stored procedures.
    /// Demonstrates legacy pattern with manual parameter mapping and result set handling.
    /// Credit evaluation is now delegated to <see cref="ICreditEvaluationService"/>.
    /// </summary>
    public class LoanDecisionRepository : ILoanDecisionRepository
    {
        private readonly string _connectionString;
        private readonly ICreditEvaluationService _creditEvalService;

        /// <summary>
        /// Initializes a new instance of the LoanDecisionRepository class with explicit dependencies.
        /// </summary>
        /// <param name="connectionString">The database connection string.</param>
        /// <param name="creditEvalService">The credit evaluation service.</param>
        public LoanDecisionRepository(string connectionString, ICreditEvaluationService creditEvalService)
        {
            _connectionString = connectionString ?? throw new ArgumentNullException(nameof(connectionString));
            _creditEvalService = creditEvalService ?? throw new ArgumentNullException(nameof(creditEvalService));
        }

        /// <summary>
        /// Initializes a new instance of the LoanDecisionRepository class.
        /// Wires up the full CreditEvaluationService dependency chain internally.
        /// </summary>
        /// <param name="connectionString">The database connection string.</param>
        public LoanDecisionRepository(string connectionString)
        {
            if (string.IsNullOrWhiteSpace(connectionString))
                throw new ArgumentNullException(nameof(connectionString));
            _connectionString = connectionString;
            var loanAppRepo = new LoanApplicationRepository(connectionString);
            var customerRepo = new CustomerRepository(connectionString);
            var rateRepo = new InterestRateRepository(connectionString);
            _creditEvalService = new CreditEvaluationService(loanAppRepo, customerRepo, rateRepo);
        }

        /// <summary>
        /// Initializes a new instance of the LoanDecisionRepository class using the default connection string.
        /// </summary>
        public LoanDecisionRepository()
            : this(ConfigurationManager.ConnectionStrings["LoanProcessingConnection"].ConnectionString)
        {
        }

        /// <summary>
        /// Performs credit evaluation for a loan application.
        /// Delegates to the CreditEvaluationService which implements the business logic
        /// previously contained in sp_EvaluateCredit.
        /// </summary>
        /// <param name="applicationId">The application ID to evaluate.</param>
        /// <returns>A LoanDecision object containing evaluation results.</returns>
        public LoanDecision EvaluateCredit(int applicationId)
        {
            return _creditEvalService.Evaluate(applicationId);
        }

        /// <summary>
        /// Processes a loan decision (approval or rejection).
        /// Calls sp_ProcessLoanDecision stored procedure which records the decision,
        /// updates application status, and triggers payment schedule calculation if approved.
        /// </summary>
        /// <param name="applicationId">The application ID to process.</param>
        /// <param name="decision">The decision (Approved or Rejected).</param>
        /// <param name="decisionBy">The name of the person making the decision.</param>
        /// <param name="comments">Optional comments about the decision.</param>
        /// <param name="approvedAmount">The approved loan amount (optional, defaults to requested amount).</param>
        /// <param name="riskScore">Optional risk score from evaluation.</param>
        /// <param name="debtToIncomeRatio">Optional debt-to-income ratio from evaluation.</param>
        /// <exception cref="ArgumentException">Thrown when decision or decisionBy is null or empty.</exception>
        /// <exception cref="SqlException">Thrown when database operation fails.</exception>
        public void ProcessDecision(int applicationId, string decision, string decisionBy,
            string comments = null, decimal? approvedAmount = null,
            int? riskScore = null, decimal? debtToIncomeRatio = null)
        {
            if (string.IsNullOrWhiteSpace(decision))
            {
                throw new ArgumentException("Decision cannot be null or empty.", nameof(decision));
            }

            if (string.IsNullOrWhiteSpace(decisionBy))
            {
                throw new ArgumentException("DecisionBy cannot be null or empty.", nameof(decisionBy));
            }

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand("sp_ProcessLoanDecision", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                // Manual parameter mapping - legacy pattern
                command.Parameters.AddWithValue("@ApplicationId", applicationId);
                command.Parameters.AddWithValue("@Decision", decision);
                command.Parameters.AddWithValue("@DecisionBy", decisionBy);
                command.Parameters.AddWithValue("@Comments",
                    string.IsNullOrWhiteSpace(comments) ? (object)DBNull.Value : comments);
                command.Parameters.AddWithValue("@ApprovedAmount",
                    approvedAmount.HasValue ? (object)approvedAmount.Value : DBNull.Value);
                command.Parameters.AddWithValue("@RiskScore",
                    riskScore.HasValue ? (object)riskScore.Value : DBNull.Value);
                command.Parameters.AddWithValue("@DebtToIncomeRatio",
                    debtToIncomeRatio.HasValue ? (object)debtToIncomeRatio.Value : DBNull.Value);

                connection.Open();
                command.ExecuteNonQuery();
            }
        }

        /// <summary>
        /// Retrieves all loan decisions for a specific application.
        /// Returns decision history including evaluation results and approval/rejection details.
        /// </summary>
        /// <param name="applicationId">The application ID to retrieve decisions for.</param>
        /// <returns>A collection of loan decisions for the application.</returns>
        public IEnumerable<LoanDecision> GetByApplication(int applicationId)
        {
            var decisions = new List<LoanDecision>();

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand())
            {
                command.Connection = connection;
                command.CommandType = CommandType.Text;
                command.CommandText = @"
                    SELECT 
                        DecisionId,
                        ApplicationId,
                        Decision,
                        DecisionBy,
                        DecisionDate,
                        Comments,
                        ApprovedAmount,
                        InterestRate,
                        RiskScore,
                        DebtToIncomeRatio
                    FROM LoanDecisions
                    WHERE ApplicationId = @ApplicationId
                    ORDER BY DecisionDate DESC";

                command.Parameters.AddWithValue("@ApplicationId", applicationId);

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        decisions.Add(MapLoanDecisionFromReader(reader));
                    }
                }
            }

            return decisions;
        }

        /// <summary>
        /// Maps a SqlDataReader row to a LoanDecision object.
        /// Demonstrates manual result mapping pattern common in legacy applications.
        /// </summary>
        /// <param name="reader">The SqlDataReader positioned at a loan decision row.</param>
        /// <returns>A LoanDecision object populated from the reader.</returns>
        private LoanDecision MapLoanDecisionFromReader(SqlDataReader reader)
        {
            return new LoanDecision
            {
                DecisionId = reader.GetInt32(reader.GetOrdinal("DecisionId")),
                ApplicationId = reader.GetInt32(reader.GetOrdinal("ApplicationId")),
                Decision = reader.GetString(reader.GetOrdinal("Decision")),
                DecisionBy = reader.GetString(reader.GetOrdinal("DecisionBy")),
                DecisionDate = reader.GetDateTime(reader.GetOrdinal("DecisionDate")),
                Comments = reader.IsDBNull(reader.GetOrdinal("Comments"))
                    ? null
                    : reader.GetString(reader.GetOrdinal("Comments")),
                ApprovedAmount = reader.IsDBNull(reader.GetOrdinal("ApprovedAmount"))
                    ? (decimal?)null
                    : reader.GetDecimal(reader.GetOrdinal("ApprovedAmount")),
                InterestRate = reader.IsDBNull(reader.GetOrdinal("InterestRate"))
                    ? (decimal?)null
                    : reader.GetDecimal(reader.GetOrdinal("InterestRate")),
                RiskScore = reader.IsDBNull(reader.GetOrdinal("RiskScore"))
                    ? (int?)null
                    : reader.GetInt32(reader.GetOrdinal("RiskScore")),
                DebtToIncomeRatio = reader.IsDBNull(reader.GetOrdinal("DebtToIncomeRatio"))
                    ? (decimal?)null
                    : reader.GetDecimal(reader.GetOrdinal("DebtToIncomeRatio"))
            };
        }
    }
}
