using LoanProcessing.Web.Models;

namespace LoanProcessing.Web.Services
{
    /// <summary>
    /// Service interface for credit evaluation operations.
    /// Replaces the sp_EvaluateCredit stored procedure logic with C# business rules.
    /// </summary>
    public interface ICreditEvaluationService
    {
        /// <summary>
        /// Evaluates credit for a loan application.
        /// Loads application and customer data, calculates DTI ratio, risk score,
        /// and recommendation, looks up the applicable interest rate, updates the
        /// application status, and returns a populated <see cref="LoanDecision"/>.
        /// </summary>
        /// <param name="applicationId">The application ID to evaluate. Must be greater than zero.</param>
        /// <returns>A <see cref="LoanDecision"/> with RiskScore, DebtToIncomeRatio, InterestRate, and Comments (recommendation).</returns>
        /// <exception cref="System.ArgumentException">Thrown when applicationId is less than or equal to zero.</exception>
        /// <exception cref="System.InvalidOperationException">Thrown when the application or customer is not found, or customer income is invalid.</exception>
        LoanDecision Evaluate(int applicationId);
    }
}
