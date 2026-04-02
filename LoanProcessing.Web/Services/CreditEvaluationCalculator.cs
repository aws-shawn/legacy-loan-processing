using System;

namespace LoanProcessing.Web.Services
{
    /// <summary>
    /// Pure static calculation functions for credit evaluation.
    /// Extracted from sp_EvaluateCredit stored procedure logic.
    /// No dependencies — all methods are deterministic and side-effect free.
    /// </summary>
    public static class CreditEvaluationCalculator
    {
        /// <summary>
        /// Default interest rate used when no matching rate is found in the InterestRates table.
        /// </summary>
        public const decimal DefaultInterestRate = 12.99m;

        /// <summary>
        /// Computes the debt-to-income ratio as a percentage.
        /// Formula: ((existingDebt + requestedAmount) / annualIncome) * 100
        /// </summary>
        /// <param name="existingDebt">Sum of approved amounts from other approved loans for the customer.</param>
        /// <param name="requestedAmount">The loan amount being requested.</param>
        /// <param name="annualIncome">The customer's annual income. Must be greater than zero.</param>
        /// <returns>The DTI ratio as a percentage.</returns>
        public static decimal CalculateDtiRatio(decimal existingDebt, decimal requestedAmount, decimal annualIncome)
        {
            return ((existingDebt + requestedAmount) / annualIncome) * 100;
        }

        /// <summary>
        /// Computes the credit score component of the risk score.
        /// Bracket mapping: 750+ → 10, 700+ → 20, 650+ → 35, 600+ → 50, below 600 → 75
        /// </summary>
        /// <param name="creditScore">The customer's credit score.</param>
        /// <returns>The credit score component value.</returns>
        public static int CalculateCreditScoreComponent(int creditScore)
        {
            if (creditScore >= 750) return 10;
            if (creditScore >= 700) return 20;
            if (creditScore >= 650) return 35;
            if (creditScore >= 600) return 50;
            return 75;
        }

        /// <summary>
        /// Computes the DTI component of the risk score.
        /// Bracket mapping: ≤20 → 0, ≤35 → 10, ≤43 → 20, >43 → 30
        /// </summary>
        /// <param name="dtiRatio">The debt-to-income ratio percentage.</param>
        /// <returns>The DTI component value.</returns>
        public static int CalculateDtiComponent(decimal dtiRatio)
        {
            if (dtiRatio <= 20) return 0;
            if (dtiRatio <= 35) return 10;
            if (dtiRatio <= 43) return 20;
            return 30;
        }

        /// <summary>
        /// Computes the total risk score as the sum of credit score and DTI components,
        /// clamped to the range [0, 100].
        /// </summary>
        /// <param name="creditScore">The customer's credit score.</param>
        /// <param name="dtiRatio">The debt-to-income ratio percentage.</param>
        /// <returns>The risk score, between 0 and 100 inclusive.</returns>
        public static int CalculateRiskScore(int creditScore, decimal dtiRatio)
        {
            int raw = CalculateCreditScoreComponent(creditScore) + CalculateDtiComponent(dtiRatio);
            return Math.Min(100, Math.Max(0, raw));
        }

        /// <summary>
        /// Determines the recommendation string based on risk score and DTI ratio.
        /// </summary>
        /// <param name="riskScore">The calculated risk score (0–100).</param>
        /// <param name="dtiRatio">The debt-to-income ratio percentage.</param>
        /// <returns>One of: "Recommended for Approval", "Manual Review Required", or "High Risk - Recommend Rejection".</returns>
        public static string DetermineRecommendation(int riskScore, decimal dtiRatio)
        {
            if (riskScore <= 30 && dtiRatio <= 35)
                return "Recommended for Approval";
            if (riskScore <= 50 && dtiRatio <= 43)
                return "Manual Review Required";
            return "High Risk - Recommend Rejection";
        }
    }
}
