using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using LoanProcessing.Web.Models;

namespace LoanProcessing.Web.Data
{
    /// <summary>
    /// Repository for interest rate data access operations.
    /// Uses direct ADO.NET for database access following legacy patterns.
    /// </summary>
    public class InterestRateRepository : IInterestRateRepository
    {
        private readonly string _connectionString;

        /// <summary>
        /// Initializes a new instance of the InterestRateRepository class.
        /// </summary>
        /// <param name="connectionString">The database connection string.</param>
        public InterestRateRepository(string connectionString)
        {
            _connectionString = connectionString ?? throw new ArgumentNullException(nameof(connectionString));
        }

        /// <summary>
        /// Gets all interest rates.
        /// </summary>
        /// <returns>Collection of all interest rates.</returns>
        public IEnumerable<InterestRate> GetAll()
        {
            var rates = new List<InterestRate>();

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand("SELECT * FROM InterestRates ORDER BY LoanType, MinCreditScore, EffectiveDate DESC", connection))
            {
                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        rates.Add(MapInterestRateFromReader(reader));
                    }
                }
            }

            return rates;
        }

        /// <summary>
        /// Gets an interest rate by ID.
        /// </summary>
        /// <param name="rateId">The rate ID.</param>
        /// <returns>The interest rate, or null if not found.</returns>
        public InterestRate GetById(int rateId)
        {
            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand("SELECT * FROM InterestRates WHERE RateId = @RateId", connection))
            {
                command.Parameters.AddWithValue("@RateId", rateId);

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        return MapInterestRateFromReader(reader);
                    }
                }
            }

            return null;
        }

        /// <summary>
        /// Gets all active interest rates (not expired).
        /// </summary>
        /// <returns>Collection of active interest rates.</returns>
        public IEnumerable<InterestRate> GetActiveRates()
        {
            var rates = new List<InterestRate>();

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand(
                "SELECT * FROM InterestRates WHERE ExpirationDate IS NULL OR ExpirationDate >= GETDATE() ORDER BY LoanType, MinCreditScore, EffectiveDate DESC", 
                connection))
            {
                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        rates.Add(MapInterestRateFromReader(reader));
                    }
                }
            }

            return rates;
        }

        /// <summary>
        /// Creates a new interest rate.
        /// </summary>
        /// <param name="rate">The interest rate to create.</param>
        /// <returns>The ID of the newly created rate.</returns>
        public int CreateRate(InterestRate rate)
        {
            if (rate == null)
            {
                throw new ArgumentNullException(nameof(rate));
            }

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand(
                @"INSERT INTO InterestRates (LoanType, MinCreditScore, MaxCreditScore, MinTermMonths, MaxTermMonths, Rate, EffectiveDate, ExpirationDate)
                  VALUES (@LoanType, @MinCreditScore, @MaxCreditScore, @MinTermMonths, @MaxTermMonths, @Rate, @EffectiveDate, @ExpirationDate);
                  SELECT CAST(SCOPE_IDENTITY() AS INT);", 
                connection))
            {
                command.Parameters.AddWithValue("@LoanType", rate.LoanType);
                command.Parameters.AddWithValue("@MinCreditScore", rate.MinCreditScore);
                command.Parameters.AddWithValue("@MaxCreditScore", rate.MaxCreditScore);
                command.Parameters.AddWithValue("@MinTermMonths", rate.MinTermMonths);
                command.Parameters.AddWithValue("@MaxTermMonths", rate.MaxTermMonths);
                command.Parameters.AddWithValue("@Rate", rate.Rate);
                command.Parameters.AddWithValue("@EffectiveDate", rate.EffectiveDate);
                command.Parameters.AddWithValue("@ExpirationDate", (object)rate.ExpirationDate ?? DBNull.Value);

                connection.Open();
                return (int)command.ExecuteScalar();
            }
        }

        /// <summary>
        /// Updates an existing interest rate.
        /// </summary>
        /// <param name="rate">The interest rate to update.</param>
        public void UpdateRate(InterestRate rate)
        {
            if (rate == null)
            {
                throw new ArgumentNullException(nameof(rate));
            }

            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand(
                @"UPDATE InterestRates 
                  SET LoanType = @LoanType,
                      MinCreditScore = @MinCreditScore,
                      MaxCreditScore = @MaxCreditScore,
                      MinTermMonths = @MinTermMonths,
                      MaxTermMonths = @MaxTermMonths,
                      Rate = @Rate,
                      EffectiveDate = @EffectiveDate,
                      ExpirationDate = @ExpirationDate
                  WHERE RateId = @RateId", 
                connection))
            {
                command.Parameters.AddWithValue("@RateId", rate.RateId);
                command.Parameters.AddWithValue("@LoanType", rate.LoanType);
                command.Parameters.AddWithValue("@MinCreditScore", rate.MinCreditScore);
                command.Parameters.AddWithValue("@MaxCreditScore", rate.MaxCreditScore);
                command.Parameters.AddWithValue("@MinTermMonths", rate.MinTermMonths);
                command.Parameters.AddWithValue("@MaxTermMonths", rate.MaxTermMonths);
                command.Parameters.AddWithValue("@Rate", rate.Rate);
                command.Parameters.AddWithValue("@EffectiveDate", rate.EffectiveDate);
                command.Parameters.AddWithValue("@ExpirationDate", (object)rate.ExpirationDate ?? DBNull.Value);

                connection.Open();
                int rowsAffected = command.ExecuteNonQuery();

                if (rowsAffected == 0)
                {
                    throw new InvalidOperationException($"Interest rate with ID {rate.RateId} not found.");
                }
            }
        }

        /// <summary>
        /// Finds the best matching interest rate for the given criteria.
        /// </summary>
        /// <param name="loanType">The loan type to match.</param>
        /// <param name="creditScore">The credit score to match within range.</param>
        /// <param name="termMonths">The term in months to match within range.</param>
        /// <param name="asOfDate">The date to check effective/expiration against.</param>
        /// <returns>The best matching interest rate, or null if no match found.</returns>
        public InterestRate GetRateByCriteria(string loanType, int creditScore, int termMonths, DateTime asOfDate)
        {
            using (var connection = new SqlConnection(_connectionString))
            using (var command = new SqlCommand(
                @"SELECT TOP 1 * FROM InterestRates 
                  WHERE LoanType = @LoanType 
                    AND @CreditScore BETWEEN MinCreditScore AND MaxCreditScore 
                    AND @TermMonths BETWEEN MinTermMonths AND MaxTermMonths 
                    AND EffectiveDate <= @AsOfDate 
                    AND (ExpirationDate IS NULL OR ExpirationDate >= @AsOfDate) 
                  ORDER BY EffectiveDate DESC",
                connection))
            {
                command.Parameters.AddWithValue("@LoanType", loanType);
                command.Parameters.AddWithValue("@CreditScore", creditScore);
                command.Parameters.AddWithValue("@TermMonths", termMonths);
                command.Parameters.AddWithValue("@AsOfDate", asOfDate);

                connection.Open();
                using (var reader = command.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        return MapInterestRateFromReader(reader);
                    }
                }
            }

            return null;
        }

        /// <summary>
        /// Maps a SqlDataReader row to an InterestRate object.
        /// </summary>
        /// <param name="reader">The data reader.</param>
        /// <returns>The mapped InterestRate object.</returns>
        private InterestRate MapInterestRateFromReader(SqlDataReader reader)
        {
            return new InterestRate
            {
                RateId = reader.GetInt32(reader.GetOrdinal("RateId")),
                LoanType = reader.GetString(reader.GetOrdinal("LoanType")),
                MinCreditScore = reader.GetInt32(reader.GetOrdinal("MinCreditScore")),
                MaxCreditScore = reader.GetInt32(reader.GetOrdinal("MaxCreditScore")),
                MinTermMonths = reader.GetInt32(reader.GetOrdinal("MinTermMonths")),
                MaxTermMonths = reader.GetInt32(reader.GetOrdinal("MaxTermMonths")),
                Rate = reader.GetDecimal(reader.GetOrdinal("Rate")),
                EffectiveDate = reader.GetDateTime(reader.GetOrdinal("EffectiveDate")),
                ExpirationDate = reader.IsDBNull(reader.GetOrdinal("ExpirationDate")) 
                    ? (DateTime?)null 
                    : reader.GetDateTime(reader.GetOrdinal("ExpirationDate"))
            };
        }
    }
}
