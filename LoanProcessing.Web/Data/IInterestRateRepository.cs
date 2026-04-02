using System;
using System.Collections.Generic;
using LoanProcessing.Web.Models;

namespace LoanProcessing.Web.Data
{
    /// <summary>
    /// Repository interface for interest rate data access operations.
    /// </summary>
    public interface IInterestRateRepository
    {
        /// <summary>
        /// Gets all interest rates.
        /// </summary>
        /// <returns>Collection of all interest rates.</returns>
        IEnumerable<InterestRate> GetAll();

        /// <summary>
        /// Gets an interest rate by ID.
        /// </summary>
        /// <param name="rateId">The rate ID.</param>
        /// <returns>The interest rate, or null if not found.</returns>
        InterestRate GetById(int rateId);

        /// <summary>
        /// Gets all active interest rates (not expired).
        /// </summary>
        /// <returns>Collection of active interest rates.</returns>
        IEnumerable<InterestRate> GetActiveRates();

        /// <summary>
        /// Creates a new interest rate.
        /// </summary>
        /// <param name="rate">The interest rate to create.</param>
        /// <returns>The ID of the newly created rate.</returns>
        int CreateRate(InterestRate rate);

        /// <summary>
        /// Updates an existing interest rate.
        /// </summary>
        /// <param name="rate">The interest rate to update.</param>
        void UpdateRate(InterestRate rate);

        /// <summary>
        /// Finds the best matching interest rate for the given criteria.
        /// Matches on loan type, credit score within [MinCreditScore, MaxCreditScore],
        /// term within [MinTermMonths, MaxTermMonths], effective on or before asOfDate,
        /// not expired as of asOfDate. Returns the most recently effective match, or null.
        /// </summary>
        /// <param name="loanType">The loan type to match.</param>
        /// <param name="creditScore">The credit score to match within range.</param>
        /// <param name="termMonths">The term in months to match within range.</param>
        /// <param name="asOfDate">The date to check effective/expiration against.</param>
        /// <returns>The best matching interest rate, or null if no match found.</returns>
        InterestRate GetRateByCriteria(string loanType, int creditScore, int termMonths, DateTime asOfDate);
    }
}
